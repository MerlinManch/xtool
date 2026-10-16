"""Native CLI integration without Apple credentials or proprietary SDK content."""
import json
import os
from pathlib import Path
import plistlib
import struct
import subprocess
import tempfile
import unittest


@unittest.skipUnless(os.name == 'nt' and os.environ.get('XTOOL_CLI'), 'native Windows CLI required')
class CLITests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='xtool CLI ü ')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.cli = Path(os.environ['XTOOL_CLI']).resolve()

    def invoke(self, *args, input=None, env=None):
        return subprocess.run([self.cli, *args], cwd=self.root, input=input,
                              capture_output=True, text=True, encoding='utf-8',
                              env=env, timeout=180)

    def test_new_project_and_native_build_server_configuration(self):
        result = self.invoke('new', '--skip-setup', 'Native-App')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        project = self.root / 'Native-App'
        self.assertIn('Native_App', (project / 'Package.swift').read_text())
        self.assertTrue((project / 'Sources/Native_App/Native_AppApp.swift').is_file())
        bsp = json.loads((project / '.bsp/xtool.json').read_text())
        self.assertEqual(bsp['argv'], ['xtool.exe', 'dev', 'build-server'])

    def test_redirected_console_prompt(self):
        result = self.invoke('new', '--skip-setup', input='Prompt-App\r\n')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue((self.root / 'Prompt-App/xtool.yml').is_file())

    def test_sdk_build_with_synthetic_xcode_layout(self):
        # Minimal PE files exercise resource validation/copying; no fake Apple
        # framework is ever compiled or represented as a real Xcode SDK.
        pe = bytearray(70)
        pe[:2] = b'MZ'
        struct.pack_into('<I', pe, 60, 64)
        pe[64:68] = b'PE\0\0'
        struct.pack_into('<H', pe, 68, 0x8664)
        tools = self.root / 'native tools/bin'
        tools.mkdir(parents=True)
        for name in ['ld64.lld.exe', 'llvm-libtool-darwin.exe', 'dsymutil.exe']:
            (tools / name).write_bytes(pe)
        macros = self.root / 'native macros'
        macros.mkdir()
        (macros / 'OpenAppleMacrosServer.exe').write_bytes(pe)
        (macros / 'companion.dll').write_bytes(b'companion resource')
        app = self.root / 'Xcode.app'
        dev = app / 'Contents/Developer'
        include = dev / 'Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/clang/include'
        include.mkdir(parents=True)
        for platform in ['iPhoneOS', 'MacOSX', 'iPhoneSimulator']:
            base = dev / f'Platforms/{platform}.platform'
            base.mkdir(parents=True)
            (base / 'Info.plist').write_bytes(plistlib.dumps({'DefaultProperties': {}}))
            sdk = base / f'Developer/SDKs/{platform}99.0.sdk/System/Library/Frameworks'
            sdk.mkdir(parents=True)
            for framework in ['Testing', 'XCTest', 'XCUIAutomation', 'XCTestCore']:
                group = 'PrivateFrameworks' if framework == 'XCTestCore' else 'Frameworks'
                target = base / f'Developer/Library/{group}/{framework}.framework'
                target.mkdir(parents=True)
                (target / 'marker').write_text(framework)
            framework = sdk / 'Example.framework'
            (framework / 'Versions/A/Headers').mkdir(parents=True)
            (framework / 'Versions/A/Headers/example.h').write_text('header')
            (framework / 'Versions/Current').symlink_to('A', target_is_directory=True)
            (framework / 'Headers').symlink_to('Versions/Current/Headers', target_is_directory=True)
        env = dict(os.environ, XTOOL_WINDOWS_TOOLSET=str(tools.parent), XTOOL_WINDOWS_MACROS=str(macros))
        result = self.invoke('sdk', 'build', str(app), str(self.root / 'output'), env=env)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        output = self.root / 'output/darwin.xtoolsdk'
        info = json.loads((output / 'info.json').read_text())
        self.assertIn('x86_64-unknown-windows-msvc', info['artifacts']['darwin']['variants'][0]['supportedTriples'])
        self.assertEqual((output / 'toolset/bin/orig/ld64.lld.exe').read_bytes(), pe)
        self.assertEqual((output / 'companion.dll').read_bytes(), b'companion resource')
        for platform in ['iPhoneOS', 'MacOSX', 'iPhoneSimulator']:
            base = output / f'Developer/Platforms/{platform}.platform'
            frameworks = base / f'Developer/SDKs/{platform}99.0.sdk/System/Library/Frameworks'
            self.assertEqual((frameworks / 'Testing.framework/marker').read_text(), 'Testing')
            self.assertTrue((frameworks / 'Example.framework/Headers').is_symlink())
            self.assertEqual((frameworks / 'Example.framework/Headers/example.h').read_text(), 'header')
            self.assertTrue((base / 'Developer/usr/bin/swift-plugin-server.exe').is_file())
        self.assertTrue((output / 'Developer/Platforms/iPhoneOS.platform/Developer/usr/lib/swift/host/plugins/SwiftUIMacros.dll').exists())
        original = app / 'Contents/Developer/Platforms/iPhoneOS.platform/Info.plist'
        self.assertEqual(plistlib.loads(original.read_bytes()), {'DefaultProperties': {}})


if __name__ == '__main__':
    unittest.main()
