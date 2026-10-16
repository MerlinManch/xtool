"""Native WinHTTP framing, failed upgrades and in-flight cancellation."""
import ctypes
import importlib.util
import os
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
            def do_GET(self):
                if self.path == '/stall':
                    cls.stalled.set()
                    cls.finish_stall.wait(10)
                    return
                return super().do_GET()

        cls.server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
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
