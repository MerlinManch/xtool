"""Regression fixtures for DLL discovery, including delayed runtime imports."""
import importlib.util
from pathlib import Path
import struct
import tempfile
import unittest
from unittest.mock import patch
from types import SimpleNamespace


spec = importlib.util.spec_from_file_location(
    'bundle_runtime', Path(__file__).resolve().parents[1] / 'bundle-runtime.py')
runtime = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runtime)


def image(machine=0x8664):
    data = bytearray(2048)
    data[:2] = b'MZ'
    struct.pack_into('<I', data, 0x3c, 128)
    data[128:132] = b'PE\0\0'
    struct.pack_into('<HH', data, 132, machine, 1)
    struct.pack_into('<H', data, 148, 240)
    struct.pack_into('<H', data, 152, 0x20b)
    struct.pack_into('<I', data, 152 + 108, 16)
    # One section at RVA 0x1000, file offset 0x200.
    struct.pack_into('<IIII', data, 152 + 240 + 8, 1536, 0x1000, 1536, 512)
    struct.pack_into('<II', data, 152 + 112 + 8, 0x1000, 40)
    struct.pack_into('<I', data, 512 + 12, 0x1100)
    data[768:768 + len(b'swiftCore.dll\0')] = b'swiftCore.dll\0'
    struct.pack_into('<II', data, 152 + 112 + 13 * 8, 0x1040, 64)
    struct.pack_into('<II', data, 576, 1, 0x1140)
    data[832:832 + len(b'Foundation.dll\0')] = b'Foundation.dll\0'
    return data


class ImportsTests(unittest.TestCase):
    def test_normal_and_delayed_imports_in_unicode_path(self):
        with tempfile.TemporaryDirectory(prefix='runtime ü ') as directory:
            path = Path(directory) / 'test.exe'
            path.write_bytes(image())
            self.assertEqual(runtime.imports(path), ['swiftCore.dll', 'Foundation.dll'])

    def test_wrong_architecture_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'test.exe'
            path.write_bytes(image(0xaa64))
            with self.assertRaisesRegex(ValueError, 'x64'):
                runtime.imports(path)

    def test_invalid_rva_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'test.exe'
            data = image()
            struct.pack_into('<I', data, 512 + 12, 0x9000)
            path.write_bytes(data)
            with self.assertRaisesRegex(ValueError, 'Unmapped RVA'):
                runtime.imports(path)


class SmokeTests(unittest.TestCase):
    def test_mixed_case_environment_and_isolated_search_path(self):
        result = SimpleNamespace(returncode=0, stdout='USAGE: xtool\n', stderr='')
        with tempfile.TemporaryDirectory() as directory:
            with patch.dict(runtime.os.environ, {
                'SystemRoot': directory, 'Path': 'C:/Swift/bin;C:/build',
                'SwiftRuntime': 'C:/Swift/runtime', 'SDKROOT': 'C:/SDK',
            }, clear=True), patch.object(runtime.subprocess, 'run', return_value=result) as run:
                runtime.smoke(Path(directory))
            self.assertEqual(run.call_count, 3)
            for call in run.call_args_list:
                environment = call.kwargs['env']
                self.assertEqual(environment['PATH'], str(Path(directory) / 'System32'))
                self.assertEqual(environment['SYSTEMROOT'], directory)
                self.assertNotIn('SWIFTRUNTIME', environment)
                self.assertNotIn('SDKROOT', environment)
                self.assertNotEqual(call.kwargs['cwd'], directory)

    def test_empty_output_is_failure_even_with_zero_exit_code(self):
        result = SimpleNamespace(returncode=0, stdout='', stderr='')
        with patch.dict(runtime.os.environ, {'SystemRoot': 'C:/Windows'}, clear=True):
            with patch.object(runtime.subprocess, 'run', return_value=result):
                with self.assertRaisesRegex(RuntimeError, '0x00000000'):
                    runtime.smoke(Path('.'))

    def test_missing_dll_status_is_reported_as_hex(self):
        result = SimpleNamespace(returncode=-1073741515, stdout='', stderr='')
        with patch.dict(runtime.os.environ, {'SystemRoot': 'C:/Windows'}, clear=True):
            with patch.object(runtime.subprocess, 'run', return_value=result):
                with self.assertRaisesRegex(RuntimeError, '0xC0000135'):
                    runtime.smoke(Path('.'))


if __name__ == '__main__':
    unittest.main()
