"""Exercise the actual Swift compiler-plugin wire protocol on native Windows."""
import json
import os
import struct
import subprocess
import unittest


def syntax(kind, source):
    return {'kind': kind, 'source': source, 'location': {
        'fileID': 'NativeWindows/Test.swift', 'fileName': 'C:/test ü/Test.swift',
        'offset': 0, 'line': 1, 'column': 1,
    }}


def frame(message):
    payload = json.dumps(message, ensure_ascii=False, separators=(',', ':')).encode('utf-8')
    return struct.pack('<Q', len(payload)) + payload


@unittest.skipUnless(os.name == 'nt' and os.environ.get('XTOOL_NATIVE_MACRO_SERVER'),
                     'native Windows macro server required')
class MacroProtocolTests(unittest.TestCase):
    def test_capability_module_loading_and_real_swiftui_expansion(self):
        messages = [
            {'getCapability': {'capability': {'protocolVersion': 8}}},
            {'loadPluginLibrary': {'libraryPath': 'C:/sdk ü/SwiftUIMacros.dll', 'moduleName': 'SwiftUIMacros'}},
            {'expandAttachedMacro': {
                'macro': {'moduleName': 'SwiftUIMacros', 'typeName': 'EntryMacro', 'name': 'Entry'},
                'macroRole': 'peer', 'discriminator': '$sNativeWindowsTest',
                'attributeSyntax': syntax('attribute', '@Entry'),
                'declSyntax': syntax('declaration', '@Entry var nativeValue: String = "Windows ü"'),
                'parentDeclSyntax': None, 'extendedTypeSyntax': None, 'conformanceListSyntax': None,
                'lexicalContext': [syntax('declaration', 'extension EnvironmentValues {}')],
            }},
            {'loadPluginLibrary': {'libraryPath': 'C:/missing.dll', 'moduleName': 'MissingWindowsTestModule'}},
        ]
        result = subprocess.run([os.environ['XTOOL_NATIVE_MACRO_SERVER']],
                                input=b''.join(map(frame, messages)), capture_output=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr.decode('utf-8', errors='replace'))
        replies = []
        cursor = 0
        while cursor < len(result.stdout):
            self.assertGreaterEqual(len(result.stdout) - cursor, 8, 'truncated protocol header')
            length, = struct.unpack_from('<Q', result.stdout, cursor)
            cursor += 8
            self.assertLessEqual(length, 2 * 1024 * 1024, 'invalid protocol length or text-mode corruption')
            self.assertLessEqual(cursor + length, len(result.stdout), 'truncated protocol payload')
            replies.append(json.loads(result.stdout[cursor:cursor + length]))
            cursor += length
        self.assertEqual(len(replies), len(messages))
        capability = replies[0]['getCapabilityResult']['capability']
        self.assertEqual(capability['protocolVersion'], 8)
        self.assertIn('load-plugin-library', capability['features'])
        self.assertTrue(replies[1]['loadPluginLibraryResult']['loaded'])
        expansion = replies[2].get('expandMacroResult') or replies[2].get('expandAttachedMacroResult')
        self.assertIsNotNone(expansion, replies[2])
        self.assertEqual(expansion['diagnostics'], [])
        source = expansion.get('expandedSource') or '\n'.join(expansion.get('expandedSources') or [])
        self.assertIn('EnvironmentKey', source)
        self.assertIn('__Key_nativeValue', source)
        self.assertIn('"Windows ü"', source)
        self.assertFalse(replies[3]['loadPluginLibraryResult']['loaded'])
        self.assertTrue(replies[3]['loadPluginLibraryResult']['diagnostics'])


if __name__ == '__main__':
    unittest.main()
