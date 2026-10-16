"""Native WinHTTP framing, failed upgrades and in-flight cancellation."""
import ctypes
import gzip
import importlib.util
import os
import ssl
import select
import socket
from pathlib import Path
import threading
import unittest
from http.server import ThreadingHTTPServer

fixture_path = Path(__file__).parents[1] / 'cli-tests/http_server.py'
spec = importlib.util.spec_from_file_location('xtool_http_fixture', fixture_path)
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)


@unittest.skipUnless(os.name == 'nt' and os.environ.get('XTOOL_WINHTTP_TEST_DLL'),
                     'native Windows WinHTTP test library required')
class WinHTTPTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.dll = ctypes.CDLL(os.environ['XTOOL_WINHTTP_TEST_DLL'])
        cls.dll.xtool_ws_connect_with_client.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_wchar_p,
            ctypes.POINTER(ctypes.c_uint32), ctypes.POINTER(ctypes.c_uint32)]
        cls.dll.xtool_http_client_create.argtypes = [ctypes.c_char_p, ctypes.c_wchar_p, ctypes.c_int,
                                                    ctypes.POINTER(ctypes.c_uint32)]
        cls.dll.xtool_http_client_create.restype = ctypes.c_void_p
        cls.dll.xtool_http_client_destroy.argtypes = [ctypes.c_void_p]
        cls.dll.xtool_http_open.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_wchar_p,
            ctypes.c_wchar_p, ctypes.c_wchar_p, ctypes.c_void_p, ctypes.c_uint32,
            ctypes.POINTER(ctypes.c_uint32), ctypes.POINTER(ctypes.c_uint32)]
        cls.dll.xtool_http_headers.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_void_p),
                                              ctypes.POINTER(ctypes.c_uint32)]
        cls.dll.xtool_http_read.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_uint32,
            ctypes.POINTER(ctypes.c_uint32), ctypes.POINTER(ctypes.c_uint32)]
        cls.dll.xtool_ws_create.restype = ctypes.c_void_p
        cls.dll.xtool_ws_connect.argtypes = [ctypes.c_void_p, ctypes.c_wchar_p,
                                            ctypes.POINTER(ctypes.c_uint32), ctypes.POINTER(ctypes.c_uint32)]
        cls.dll.xtool_ws_send.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_uint32,
                                         ctypes.c_int, ctypes.POINTER(ctypes.c_uint32)]
        cls.dll.xtool_ws_receive.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_void_p),
            ctypes.POINTER(ctypes.c_uint32), ctypes.POINTER(ctypes.c_int),
            ctypes.POINTER(ctypes.c_uint32), ctypes.POINTER(ctypes.c_uint32)]
        for name in ['xtool_ws_abort', 'xtool_ws_destroy', 'xtool_ws_shutdown', 'xtool_ws_release_data']:
            getattr(cls.dll, name).argtypes = [ctypes.c_void_p]
        cls.stalled = threading.Event()
        cls.finish_stall = threading.Event()

        class Handler(fixture.Handler):
            def do_POST(self):
                data = self.rfile.read(int(self.headers['Content-Length']))
                self.send_response(200)
                self.send_header('Content-Length', str(len(data)))
                self.send_header('X-Duplicate', 'first')
                self.send_header('X-Duplicate', 'second')
                self.end_headers()
                self.wfile.write(data)

            def do_GET(self):
                self.server.received_paths.append(self.path)
                if self.path == '/gzip':
                    data = gzip.compress('native gzip ü'.encode())
                    self.send_response(200)
                    self.send_header('Content-Length', str(len(data)))
                    self.send_header('Content-Encoding', 'gzip')
                    self.end_headers()
                    self.wfile.write(data)
                    return
                if self.path in ('/cookie/set', '/cookie/read'):
                    data = self.headers.get('Cookie', '').encode()
                    self.send_response(200)
                    self.send_header('Content-Length', str(len(data)))
                    if self.path.endswith('set'):
                        self.send_header('Set-Cookie', 'xtool=native; Path=/; HttpOnly')
                    self.end_headers()
                    self.wfile.write(data)
                    return
                if self.path == '/redirect':
                    self.send_response(302)
                    self.send_header('Location', '/')
                    self.send_header('Content-Length', '0')
                    self.end_headers()
                    return
                if self.path == '/pending-read':
                    self.send_response(200)
                    self.send_header('Content-Length', '8')
                    self.end_headers()
                    self.wfile.flush()
                    cls.finish_stall.wait(10)
                    return
                if self.path == '/stall':
                    cls.stalled.set()
                    cls.finish_stall.wait(10)
                    return
                return super().do_GET()

        cls.server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        cls.server.received_paths = []
        cls.handler = Handler
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
        cls.base = f'http://127.0.0.1:{cls.server.server_port}'

    @classmethod
    def tearDownClass(cls):
        cls.finish_stall.set()
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join(2)

    def create(self):
        state = self.dll.xtool_ws_create()
        self.assertTrue(state)
        self.addCleanup(self.dll.xtool_ws_destroy, state)
        return state

    def connect(self, state, path='/ws'):
        error, status = ctypes.c_uint32(), ctypes.c_uint32()
        result = self.dll.xtool_ws_connect(state, self.base + path, ctypes.byref(error), ctypes.byref(status))
        return result, error.value, status.value

    def receive(self, state):
        data, count = ctypes.c_void_p(), ctypes.c_uint32()
        text, closed, error = ctypes.c_int(), ctypes.c_uint32(), ctypes.c_uint32()
        result = self.dll.xtool_ws_receive(state, ctypes.byref(data), ctypes.byref(count),
                                          ctypes.byref(text), ctypes.byref(closed), ctypes.byref(error))
        try:
            body = ctypes.string_at(data, count.value) if count.value else b''
            return result, error.value, text.value, closed.value, body
        finally:
            self.dll.xtool_ws_release_data(data)

    def client(self, trusted=True, proxy=None):
        roots = (Path(__file__).parent / 'fixtures/ca.pem').read_bytes() if trusted else None
        error = ctypes.c_uint32()
        client = self.dll.xtool_http_client_create(roots, proxy, 0, ctypes.byref(error))
        self.assertTrue(client, error.value)
        self.addCleanup(self.dll.xtool_http_client_destroy, client)
        return client

    def open_http(self, client, url, body=None):
        state = self.create()
        error, status = ctypes.c_uint32(), ctypes.c_uint32()
        buffer = ctypes.create_string_buffer(body) if body is not None else None
        result = self.dll.xtool_http_open(state, client, url, 'POST' if body is not None else 'GET',
            'Content-Type: application/octet-stream\r\n' if body is not None else '',
            buffer, len(body) if body is not None else 0, ctypes.byref(error), ctypes.byref(status))
        return state, result, error.value, status.value

    def read_http(self, state):
        data = bytearray()
        buffer = ctypes.create_string_buffer(16384)
        while True:
            error, count = ctypes.c_uint32(), ctypes.c_uint32()
            result = self.dll.xtool_http_read(state, buffer, len(buffer), ctypes.byref(count), ctypes.byref(error))
            self.assertEqual(result, 1, error.value)
            if not count.value:
                return bytes(data)
            data.extend(buffer.raw[:count.value])

    def tls_server(self, certificate):
        server = ThreadingHTTPServer(('127.0.0.1', 0), self.handler)
        server.received_paths = []
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        fixtures = Path(__file__).parent / 'fixtures'
        context.load_cert_chain(fixtures / certificate, fixtures / 'key.pem')
        server.socket = context.wrap_socket(server.socket, server_side=True)
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        def cleanup():
            server.shutdown()
            server.server_close()
            worker.join(2)
        self.addCleanup(cleanup)
        return server, f'https://127.0.0.1:{server.server_port}/'

    def test_native_http_post_streaming_and_duplicate_headers(self):
        body = bytes(range(256)) * 4096
        state, result, error, status = self.open_http(self.client(), self.base + '/', body)
        self.assertEqual((result, error, status), (1, 0, 200))
        headers, failure = ctypes.c_void_p(), ctypes.c_uint32()
        self.assertEqual(self.dll.xtool_http_headers(state, ctypes.byref(headers), ctypes.byref(failure)), 1)
        try:
            raw = ctypes.wstring_at(headers).lower()
            self.assertIn('x-duplicate: first', raw)
            self.assertIn('x-duplicate: second', raw)
        finally:
            self.dll.xtool_ws_release_data(headers)
        self.assertEqual(self.read_http(state), body)

    def test_http_redirect_decompression_and_session_cookie_isolation(self):
        client = self.client()
        for path, expected in [('/redirect', 'native HTTP ü'.encode()),
                               ('/gzip', 'native gzip ü'.encode()), ('/cookie/set', b''),
                               ('/cookie/read', b'xtool=native')]:
            state, result, error, status = self.open_http(client, self.base + path)
            self.assertEqual((result, error, status), (1, 0, 200))
            self.assertEqual(self.read_http(state), expected)
        state, result, error, status = self.open_http(self.client(), self.base + '/cookie/read')
        self.assertEqual((result, error, status), (1, 0, 200))
        self.assertEqual(self.read_http(state), b'')

    def test_additional_roots_validate_without_modifying_windows_trust(self):
        server, url = self.tls_server('localhost.pem')
        state, result, error, status = self.open_http(self.client(), url)
        self.assertEqual((result, error, status), (1, 0, 200))
        self.assertEqual(self.read_http(state), 'native HTTP ü'.encode())
        self.assertEqual(server.received_paths, ['/'])
        _, result, error, _ = self.open_http(self.client(trusted=False), url)
        self.assertEqual(result, 0)
        self.assertNotEqual(error, 0)
        self.assertEqual(server.received_paths, ['/'], 'untrusted server received HTTP credentials/headers')

    def test_tls_websocket_uses_additional_roots(self):
        _, base = self.tls_server('localhost.pem')
        state = self.create()
        error, status = ctypes.c_uint32(), ctypes.c_uint32()
        result = self.dll.xtool_ws_connect_with_client(state, self.client(), base + 'ws',
            ctypes.byref(error), ctypes.byref(status))
        self.assertEqual((result, error.value, status.value), (1, 0, 101))
        data = b'native TLS WebSocket'
        buffer = ctypes.create_string_buffer(data)
        self.assertEqual(self.dll.xtool_ws_send(state, buffer, len(data), 1, ctypes.byref(error)), 1, error.value)
        self.assertEqual(self.receive(state), (1, 0, 1, 0, data))
        self.dll.xtool_ws_shutdown(state)

    def test_https_proxy_tunnel_preserves_certificate_validation(self):
        class Proxy(fixture.BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_CONNECT(self):
                host, port = self.path.rsplit(':', 1)
                with socket.create_connection((host, int(port)), timeout=3) as upstream:
                    self.send_response(200, 'Connection Established')
                    self.end_headers()
                    self.wfile.flush()
                    peers = [self.connection, upstream]
                    while True:
                        readable, _, _ = select.select(peers, [], [], 3)
                        if not readable:
                            return
                        for peer in readable:
                            data = peer.recv(65536)
                            if not data:
                                return
                            (upstream if peer is self.connection else self.connection).sendall(data)
        proxy = ThreadingHTTPServer(('127.0.0.1', 0), Proxy)
        proxy.daemon_threads = True
        worker = threading.Thread(target=proxy.serve_forever, daemon=True)
        worker.start()
        def cleanup():
            proxy.shutdown()
            proxy.server_close()
            worker.join(2)
        self.addCleanup(cleanup)
        server, url = self.tls_server('localhost.pem')
        named_proxy = f'127.0.0.1:{proxy.server_port}'
        state, result, error, status = self.open_http(self.client(proxy=named_proxy), url)
        self.assertEqual((result, error, status), (1, 0, 200))
        self.assertEqual(self.read_http(state), 'native HTTP ü'.encode())
        _, result, error, _ = self.open_http(self.client(trusted=False, proxy=named_proxy), url)
        self.assertEqual(result, 0)
        self.assertNotEqual(error, 0)
        self.assertEqual(server.received_paths, ['/'])

    def test_expired_and_wrong_hostname_certificates_never_receive_http(self):
        for certificate in ['expired.pem', 'wrong-host.pem']:
            with self.subTest(certificate=certificate):
                server, url = self.tls_server(certificate)
                _, result, error, _ = self.open_http(self.client(), url)
                self.assertEqual(result, 0)
                self.assertNotEqual(error, 0)
                self.assertEqual(server.received_paths, [])

    def test_abort_interrupts_pending_http_read(self):
        state, result, error, status = self.open_http(self.client(), self.base + '/pending-read')
        self.assertEqual((result, error, status), (1, 0, 200))
        responses = []
        def read():
            buffer, count, error = ctypes.create_string_buffer(32), ctypes.c_uint32(), ctypes.c_uint32()
            result = self.dll.xtool_http_read(state, buffer, len(buffer), ctypes.byref(count), ctypes.byref(error))
            responses.append((result, error.value))
        worker = threading.Thread(target=read, daemon=True)
        worker.start()
        threading.Event().wait(0.05)
        self.dll.xtool_ws_abort(state)
        worker.join(3)
        self.assertFalse(worker.is_alive(), 'native HTTP read did not cancel')
        self.assertEqual(responses[0][0], 0)
        self.assertNotEqual(responses[0][1], 0)

    def test_text_binary_and_empty_fragmented_echo(self):
        state = self.create()
        self.assertEqual(self.connect(state), (1, 0, 101))
        for text, data in [(1, 'Windows WebSocket ü 🔌'.encode()), (0, bytes(range(256)) * 2), (1, b''), (0, b'')]:
            with self.subTest(text=text, length=len(data)):
                error = ctypes.c_uint32()
                buffer = ctypes.create_string_buffer(data)
                self.assertEqual(self.dll.xtool_ws_send(state, buffer, len(data), text, ctypes.byref(error)),
                                 1, error.value)
                self.assertEqual(self.receive(state), (1, 0, text, 0, data))
        self.dll.xtool_ws_shutdown(state)

    def test_failed_upgrade_returns_status_without_opening_socket(self):
        state = self.create()
        result, error, status = self.connect(state, '/failure')
        self.assertEqual(result, 0)
        self.assertNotEqual(error, 0)
        self.assertEqual(status, 503)

    def test_abort_interrupts_pending_receive(self):
        state = self.create()
        self.assertEqual(self.connect(state), (1, 0, 101))
        result = []
        worker = threading.Thread(target=lambda: result.append(self.receive(state)), daemon=True)
        worker.start()
        threading.Event().wait(0.05)
        self.dll.xtool_ws_abort(state)
        worker.join(3)
        self.assertFalse(worker.is_alive(), 'native receive did not cancel')
        self.assertEqual(result[0][0], 0)
        self.assertNotEqual(result[0][1], 0)

    def test_abort_interrupts_pending_handshake(self):
        state = self.create()
        result = []
        self.stalled.clear()
        worker = threading.Thread(target=lambda: result.append(self.connect(state, '/stall')), daemon=True)
        worker.start()
        self.assertTrue(self.stalled.wait(3), 'handshake fixture was not reached')
        self.dll.xtool_ws_abort(state)
        worker.join(3)
        self.assertFalse(worker.is_alive(), 'native handshake did not cancel')
        self.assertEqual(result[0][0], 0)
        self.assertNotEqual(result[0][1], 0)


if __name__ == '__main__':
    unittest.main()
