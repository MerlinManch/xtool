"""Native XADI DLL tests. Apple ID credentials and provisioning are not used."""
import ctypes
import os
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
            self.assertEqual(self.runtime.xadi_LoadChecked(libraries.as_posix().encode()), 0)
            self.assertEqual(self.runtime.xadi_SetAndroidID(b'1234567890abcdef', 16), 0)
            provision = root / 'provision'
            provision.mkdir()
            self.assertEqual(self.runtime.xadi_SetProvisioningPath(provision.as_posix().encode()), 0)
            # A fresh, unprovisioned device must ask for login rather than crash
            # when the Windows-to-SysV thunk calls back into the Apple libraries.
            self.assertEqual(self.runtime.xadi_GetLoginCode(ctypes.c_uint64(-2).value), -45061)


if __name__ == '__main__':
    unittest.main()
