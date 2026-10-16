"""Loopback-only HTTP/WebSocket fixture for the native Swift network client."""
import base64
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import struct
import sys


class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *args):
        pass

    def read_exact(self, count):
        result = bytearray()
        while len(result) < count:
            chunk = self.rfile.read(count - len(result))
            if not chunk:
                raise EOFError()
            result.extend(chunk)
        return result

    def do_GET(self):
        if self.path != '/ws':
            body = 'native HTTP ü'.encode()
            self.send_response(503 if self.path == '/failure' else 200)
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self.close_connection = True
        key = self.headers['Sec-WebSocket-Key']
        accept = base64.b64encode(hashlib.sha1((key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest())
        self.send_response(101)
        self.send_header('Upgrade', 'websocket')
        self.send_header('Connection', 'Upgrade')
        self.send_header('Sec-WebSocket-Accept', accept.decode())
        self.end_headers()
        try:
            while True:
                first, second = self.read_exact(2)
                opcode = first & 15
                length = second & 127
                if length == 126:
                    length = struct.unpack('>H', self.read_exact(2))[0]
                elif length == 127:
                    length = struct.unpack('>Q', self.read_exact(8))[0]
                if length > 1024 * 1024:
                    raise ValueError('fixture frame too large')
                mask = self.read_exact(4) if second & 128 else None
                payload = self.read_exact(length)
                if mask:
                    payload = bytes(value ^ mask[index % 4] for index, value in enumerate(payload))
                if opcode == 8:
                    self.wfile.write(bytes([0x88, len(payload)]) + payload)
                    break
                if opcode == 9:
                    self.wfile.write(bytes([0x8a, len(payload)]) + payload)
                elif opcode in (1, 2):
                    # Fragment the response to check UTF-8/binary reassembly.
                    half = len(payload) // 2
                    for flag, fragment in [(opcode, payload[:half]), (0x80, payload[half:])]:
                        header = bytes([flag, len(fragment)]) if len(fragment) < 126 else bytes([flag, 126]) + struct.pack('>H', len(fragment))
                        self.wfile.write(header + fragment)
                self.wfile.flush()
        except (EOFError, OSError):
            pass


if __name__ == '__main__':
    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    Path(sys.argv[1]).write_text(str(server.server_port))
    server.serve_forever()
