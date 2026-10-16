"""Native XADI DLL tests. Apple ID credentials and provisioning are not used."""
import ctypes
import os
import subprocess
import sys
from pathlib import Path
import tempfile
import unittest
import urllib.request
import zipfile


@unittest.skipUnless(os.name == 'nt' and os.environ.get('XTOOL_ANISETTE_DLL'), 'native Windows XADI DLL required')
class AnisetteRuntimeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.runtime = ctypes.CDLL(str(Path(os.environ['XTOOL_ANISETTE_DLL']).resolve()))
        cls.runtime.xadi_LoadChecked.argtypes = [ctypes.c_char_p]
        cls.runtime.xadi_LoadChecked.restype = ctypes.c_int32
        cls.runtime.xadi_SetAndroidID.argtypes = [ctypes.c_char_p, ctypes.c_uint32]
        cls.runtime.xadi_SetProvisioningPath.argtypes = [ctypes.c_char_p]
        cls.runtime.xadi_GetLoginCode.argtypes = [ctypes.c_uint64]
        cls.runtime.xadi_GetLoginCode.restype = ctypes.c_int32

    def test_required_exports(self):
        for name in ['LoadChecked', 'SetAndroidID', 'SetProvisioningPath', 'ProvisioningErase',
                     'Synchronize', 'ProvisioningDestroy', 'ProvisioningEnd', 'ProvisioningStart',
                     'GetLoginCode', 'Dispose', 'OTPRequest']:
            self.assertIsNotNone(getattr(self.runtime, 'xadi_' + name))

    def test_missing_libraries_return_error_across_c_abi(self):
        with tempfile.TemporaryDirectory(prefix='xtool-adi-empty-') as empty:
            self.assertEqual(self.runtime.xadi_LoadChecked(empty.encode()), -1000001)

    @unittest.skipUnless(os.environ.get('XTOOL_TEST_APPLE_LIBRARIES') == '1', 'Apple APK download not enabled')
    def test_apple_libraries_initialize_locally(self):
        with tempfile.TemporaryDirectory(prefix='xtool-adi-') as tmp:
            root = Path(tmp)
            apk = root / 'applemusic.apk'
            urllib.request.urlretrieve(
                'https://apps.mzstatic.com/content/android-apple-music-apk/applemusic.apk', apk)
            libraries = root / 'libs'
            libraries.mkdir()
            with zipfile.ZipFile(apk) as archive:
                for name in ['libCoreADI.so', 'libstoreservicescore.so']:
                    (libraries / name).write_bytes(archive.read('lib/x86_64/' + name))
            provision = root / 'provision'
            provision.mkdir()
            # ELF mappings keep the source files open on Windows. Exercise the
            # ABI in a child so the OS releases mappings before directory cleanup.
            probe = r"""
import ctypes
import sys
runtime = ctypes.CDLL(sys.argv[1])
runtime.xadi_LoadChecked.argtypes = [ctypes.c_char_p]
runtime.xadi_SetAndroidID.argtypes = [ctypes.c_char_p, ctypes.c_uint32]
runtime.xadi_SetProvisioningPath.argtypes = [ctypes.c_char_p]
runtime.xadi_GetLoginCode.argtypes = [ctypes.c_uint64]
assert runtime.xadi_LoadChecked(sys.argv[2].encode()) == 0
assert runtime.xadi_SetAndroidID(b'1234567890abcdef', 16) == 0
assert runtime.xadi_SetProvisioningPath(sys.argv[3].encode()) == 0
# A fresh device must request login through the Windows-to-SysV thunk.
assert runtime.xadi_GetLoginCode(ctypes.c_uint64(-2).value) == -45061
"""
            subprocess.run([sys.executable, '-c', probe,
                            str(Path(os.environ['XTOOL_ANISETTE_DLL']).resolve()),
                            libraries.as_posix(), provision.as_posix()], check=True)



if __name__ == '__main__':
    unittest.main()
