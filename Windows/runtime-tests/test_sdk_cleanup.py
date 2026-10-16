"""Run SDK cleanup regressions against the assembled Windows CLI."""
import ctypes
from ctypes import wintypes
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest


@unittest.skipUnless(os.name == 'nt' and os.environ.get('XTOOL_CLI'),
                     'native Windows CLI required')
class SDKCleanupTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='xtool cleanup ü ')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.cli = Path(os.environ['XTOOL_CLI']).resolve()
        self.env = dict(os.environ, XDG_CONFIG_HOME=str(self.root / 'config'))
        # Test the packaged runtime, without resolving DLLs from Swift's PATH.
        self.env['PATH'] = str(Path(os.environ['SystemRoot']) / 'System32')
        self.sdks = self.root / 'config/swiftpm/swift-sdks'
        self.retained = self.root / 'retained.3pm'
        self.addCleanup(lambda: self.retained.chmod(stat.S_IWRITE)
                        if self.retained.exists() else None)
        self.decoy = self.root / 'Algorithm__Diff.3pm'
        self.decoy.write_text('CWD decoy')


    def make_link_readonly(self, link):
        # Open the reparse point itself: modifying a target's attributes would
        # not reproduce a readonly symlink left by archive extraction.
        class BasicInfo(ctypes.Structure):
            _fields_ = [('CreationTime', ctypes.c_longlong),
                        ('LastAccessTime', ctypes.c_longlong),
                        ('LastWriteTime', ctypes.c_longlong),
                        ('ChangeTime', ctypes.c_longlong),
                        ('FileAttributes', wintypes.DWORD)]
        kernel = ctypes.WinDLL('kernel32', use_last_error=True)
        kernel.CreateFileW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD,
                                      ctypes.c_void_p, wintypes.DWORD, wintypes.DWORD, wintypes.HANDLE]
        kernel.CreateFileW.restype = wintypes.HANDLE
        kernel.SetFileInformationByHandle.argtypes = [wintypes.HANDLE, ctypes.c_int,
                                                     ctypes.c_void_p, wintypes.DWORD]
        kernel.SetFileInformationByHandle.restype = wintypes.BOOL
        kernel.CloseHandle.argtypes = [wintypes.HANDLE]
        kernel.CloseHandle.restype = wintypes.BOOL
        handle = kernel.CreateFileW(str(link), 0x100, 7, None, 3, 0x02200000, None)
        if handle == ctypes.c_void_p(-1).value:
            raise ctypes.WinError(ctypes.get_last_error())
        try:
            info = BasicInfo()
            info.FileAttributes = stat.FILE_ATTRIBUTE_READONLY
            if not kernel.SetFileInformationByHandle(handle, 0, ctypes.byref(info), ctypes.sizeof(info)):
                raise ctypes.WinError(ctypes.get_last_error())
        finally:
            kernel.CloseHandle(handle)
        self.assertTrue(link.lstat().st_file_attributes & stat.FILE_ATTRIBUTE_READONLY)

    def fixture(self, name):
        bundle = self.sdks / name
        directory = bundle / 'Xcode.app/Contents/Developer/usr/share/man'
        directory.mkdir(parents=True)
        payload = directory / self.decoy.name
        payload.write_text('readonly payload')
        os.link(payload, self.retained)
        payload.chmod(stat.S_IREAD)
        (directory / 'readonly-alias').symlink_to(Path(payload.name))
        (directory / 'dangling').symlink_to(Path('absent'))
        self.make_link_readonly(directory / 'readonly-alias')
        self.make_link_readonly(directory / 'dangling')
        outside = self.root / 'outside'
        outside.mkdir()
        (outside / 'keep').write_text('external file')
        (bundle / 'directory-link').symlink_to(outside, target_is_directory=True)
        return bundle

    def invoke(self, *args):
        return subprocess.run([self.cli, *args], cwd=self.root, env=self.env,
                              capture_output=True, text=True, encoding='utf-8', timeout=60)

    def check_retained(self, bundle):
        self.assertFalse(bundle.exists(), 'SDK tree survived cleanup')
        self.assertEqual(self.decoy.read_text(), 'CWD decoy')
        self.assertEqual(self.retained.read_text(), 'readonly payload')
        self.assertTrue(self.retained.stat().st_file_attributes & stat.FILE_ATTRIBUTE_READONLY,
                        'Cleanup changed attributes of a surviving hardlink')
        self.assertEqual((self.root / 'outside/keep').read_text(), 'external file')

    def test_remove_readonly_sdk(self):
        bundle = self.fixture('darwin.artifactbundle')
        result = self.invoke('sdk', 'remove')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.check_retained(bundle)

    def test_install_cleans_interrupted_extraction_before_input_validation(self):
        bundle = self.fixture('darwin.artifactbundle.tmp')
        missing = self.root / 'missing.xip'
        result = self.invoke('sdk', 'install', str(missing))
        # Missing input is deliberate: cleanup must finish before validation
        # and must reach the expected next error without requiring Xcode.
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Could not read file or directory', result.stdout + result.stderr)
        self.check_retained(bundle)


if __name__ == '__main__':
    unittest.main()
