"""Functional tests for the native SDK helpers; runs on Windows and Unix."""
import hashlib
import json
import lzma
import os
from pathlib import Path
import shutil
import stat
import struct
import subprocess
import tempfile
import unittest
import zlib
import zipfile

SUFFIX = '.exe' if os.name == 'nt' else ''
BIN = Path(os.environ.get('XTOOL_NATIVE_BIN', '.')).resolve()


def cpio_entry(name, data=b'', mode=stat.S_IFREG | 0o644, inode=1, links=1):
    name = name.encode() + b'\0'
    values = [0, inode, mode, 0, 0, links, 0]
    return (b'070707' + b''.join(f'{v:06o}'.encode() for v in values)
            + b'00000000000' + f'{len(name):06o}{len(data):011o}'.encode() + name + data)


def pbzx(data, raw=False):
    chunk_size = 1024
    result = b'pbzx' + struct.pack('>Q', chunk_size)
    for offset in range(0, len(data) + 1, chunk_size):
        chunk = data[offset:offset + chunk_size]
        encoded = chunk if raw and len(chunk) == chunk_size else lzma.compress(chunk)
        result += struct.pack('>QQ', len(chunk), len(encoded)) + encoded
    return result


def xar(content):
    digest = hashlib.sha1(content).hexdigest()
    toc = (f'<xar><toc><file id="1"><name>Content</name><type>file</type><data>'
           f'<length>{len(content)}</length><offset>0</offset><size>{len(content)}</size>'
           f'<encoding style="application/octet-stream"/>'
           f'<extracted-checksum style="sha1">{digest}</extracted-checksum>'
           f'<archived-checksum style="sha1">{digest}</archived-checksum>'
           f'</data></file></toc></xar>').encode()
    compressed = zlib.compress(toc)
    return struct.pack('>4sHHQQI', b'xar!', 28, 1, len(compressed), len(toc), 0) + compressed + content


class XIPTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='xtool native ü ')
        self.root = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def extract(self, data):
        source = self.root / 'Xcode test.xip'
        source.write_bytes(data)
        output = self.root / 'output with spaces'
        result = subprocess.run([BIN / ('xtool-unxip' + SUFFIX), source, output], capture_output=True)
        return result, output

    def test_compressed_and_raw_multichunk_archives(self):
        payload = bytes(range(256)) * 31
        cpio = (cpio_entry('Xcode.app', mode=stat.S_IFDIR | 0o755)
                + cpio_entry('Xcode.app/ünicode test', payload, inode=2)
                + cpio_entry('TRAILER!!!', inode=0))
        for raw in (False, True):
            with self.subTest(raw=raw):
                result, output = self.extract(xar(pbzx(cpio, raw=raw)))
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual((output / 'Xcode.app/ünicode test').read_bytes(), payload)
                shutil.rmtree(output)

    def test_long_sdk_paths(self):
        name = 'Xcode.app/' + 'nested SDK directory/' * 20 + 'header.h'
        cpio = cpio_entry(name, b'long path', inode=2) + cpio_entry('TRAILER!!!', inode=0)
        result, output = self.extract(xar(pbzx(cpio)))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((output / name).read_bytes(), b'long path')

    def test_symlink_and_hardlink(self):
        cpio = (cpio_entry('Xcode.app', mode=stat.S_IFDIR | 0o755)
                + cpio_entry('Xcode.app/original', b'linked', inode=2, links=2)
                + cpio_entry('Xcode.app/hardlink', b'', inode=2, links=2)
                + cpio_entry('Xcode.app/symlink', b'original', mode=stat.S_IFLNK | 0o777, inode=3)
                + cpio_entry('TRAILER!!!', inode=0))
        result, output = self.extract(xar(pbzx(cpio)))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((output / 'Xcode.app/hardlink').read_bytes(), b'linked')
        self.assertEqual(os.readlink(output / 'Xcode.app/symlink'), 'original')

    def test_forward_directory_symlink_and_chain(self):
        cpio = (cpio_entry('Xcode.app', mode=stat.S_IFDIR | 0o755)
                + cpio_entry('Xcode.app/Headers', b'Current/Headers', mode=stat.S_IFLNK | 0o777, inode=2)
                + cpio_entry('Xcode.app/Current', b'Versions/A', mode=stat.S_IFLNK | 0o777, inode=3)
                + cpio_entry('Xcode.app/Versions/A/Headers', mode=stat.S_IFDIR | 0o755, inode=4)
                + cpio_entry('Xcode.app/Versions/A/Headers/test.h', b'header', inode=5)
                + cpio_entry('TRAILER!!!', inode=0))
        result, output = self.extract(xar(pbzx(cpio)))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((output / 'Xcode.app/Headers').is_dir())
        self.assertEqual((output / 'Xcode.app/Headers/test.h').read_bytes(), b'header')

    def test_exact_chunk_boundary(self):
        cpio = cpio_entry('test', b'hello') + cpio_entry('TRAILER!!!', inode=0)
        cpio += b'\0' * (1024 - len(cpio))
        result, output = self.extract(xar(pbzx(cpio)))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((output / 'test').read_bytes(), b'hello')

    def test_rejects_parent_traversal(self):
        cpio = cpio_entry('../escape', b'bad') + cpio_entry('TRAILER!!!', inode=0)
        result, _ = self.extract(xar(pbzx(cpio)))
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / 'escape').exists())

    def test_rejects_absolute_paths(self):
        cpio = cpio_entry(str(self.root / 'escape'), b'bad') + cpio_entry('TRAILER!!!', inode=0)
        result, _ = self.extract(xar(pbzx(cpio)))
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / 'escape').exists())

    def test_rejects_symlink_escape(self):
        cpio = (cpio_entry('escape', b'..', mode=stat.S_IFLNK | 0o777)
                + cpio_entry('escape/bad', b'bad', inode=2)
                + cpio_entry('TRAILER!!!', inode=0))
        result, _ = self.extract(xar(pbzx(cpio)))
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / 'bad').exists())

    def test_rejects_truncated_stream_and_corrupt_xz(self):
        valid = pbzx(cpio_entry('test', b'hello') + cpio_entry('TRAILER!!!', inode=0))
        for invalid in (valid[:-8], b'wrong magic', valid[:28] + b'bad XZ stream'):
            with self.subTest(length=len(invalid)):
                result, _ = self.extract(xar(invalid))
                self.assertNotEqual(result.returncode, 0)

    def test_rejects_huge_chunk_before_allocating(self):
        result, _ = self.extract(xar(b'pbzx' + struct.pack('>Q', 2**63)))
        self.assertNotEqual(result.returncode, 0)


class ZIPTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='xtool IPA ü ')
        self.root = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def invoke(self, command, source, destination):
        return subprocess.run([BIN / ('xtool-zip' + SUFFIX), command, source, destination], capture_output=True)

    def test_bundle_roundtrip_and_executable_permissions(self):
        payload = self.root / 'Payload'
        app = payload / 'App.app'
        app.mkdir(parents=True)
        (app / 'App').write_bytes(bytes.fromhex('cffaedfe') + b'executable')
        (app / 'über resource').write_bytes(b'resource contents')
        (app / '.hidden').write_bytes(b'hidden')
        os.symlink('über resource', app / 'link')
        archive = self.root / 'test.ipa'
        result = self.invoke('compress', payload, archive)
        self.assertEqual(result.returncode, 0, result.stderr)
        with zipfile.ZipFile(archive) as ipa:
            self.assertEqual(ipa.getinfo('Payload/App.app/App').external_attr >> 16 & 0o777, 0o755)
            self.assertEqual(ipa.getinfo('Payload/App.app/über resource').external_attr >> 16 & 0o777, 0o644)
            self.assertTrue(stat.S_ISLNK(ipa.getinfo('Payload/App.app/link').external_attr >> 16))
            self.assertEqual(ipa.read('Payload/App.app/.hidden'), b'hidden')
        output = self.root / 'output'
        result = self.invoke('extract', archive, output)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((output / 'Payload/App.app/App').read_bytes(), (app / 'App').read_bytes())
        self.assertEqual(os.readlink(output / 'Payload/App.app/link'), 'über resource')

    def test_native_symlink_targets_use_posix_separators_in_ipa(self):
        payload = self.root / 'Payload'
        app = payload / 'App.app'
        target = Path('Resources/sub dir/über.bin')
        (app / target).parent.mkdir(parents=True)
        (app / target).write_bytes(b'nested resource')
        (app / 'nested link').symlink_to(target)
        self.assertEqual((app / 'nested link').read_bytes(), b'nested resource')
        archive = self.root / 'nested.ipa'
        result = self.invoke('compress', payload, archive)
        self.assertEqual(result.returncode, 0, result.stderr)
        with zipfile.ZipFile(archive) as ipa:
            self.assertEqual(ipa.read('Payload/App.app/nested link'),
                             'Resources/sub dir/über.bin'.encode('utf-8'))
        output = self.root / 'nested-output'
        result = self.invoke('extract', archive, output)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((output / 'Payload/App.app/nested link').read_bytes(), b'nested resource')

    def test_extract_long_bundle_paths(self):
        archive = self.root / 'long.ipa'
        name = 'Payload/App.app/' + 'nested resources/' * 20 + 'resource'
        with zipfile.ZipFile(archive, 'w') as ipa:
            ipa.writestr(name, 'long path')
        output = self.root / 'long-output'
        result = self.invoke('extract', archive, output)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((output / name).read_text(), 'long path')

    def test_extract_forward_directory_symlink_and_chain(self):
        archive = self.root / 'framework.ipa'
        with zipfile.ZipFile(archive, 'w') as ipa:
            for name, target in [('Headers', 'Current/Headers'), ('Current', 'Versions/A')]:
                link = zipfile.ZipInfo('Framework/' + name)
                link.create_system = 3
                link.external_attr = (stat.S_IFLNK | 0o777) << 16
                ipa.writestr(link, target)
            ipa.writestr('Framework/Versions/A/Headers/test.h', 'header')
        output = self.root / 'framework-output'
        result = self.invoke('extract', archive, output)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((output / 'Framework/Headers').is_dir())
        self.assertEqual((output / 'Framework/Headers/test.h').read_text(), 'header')

    def test_extraction_rejects_parent_traversal(self):
        archive = self.root / 'bad.ipa'
        with zipfile.ZipFile(archive, 'w') as ipa:
            ipa.writestr('../escape', 'bad')
        result = self.invoke('extract', archive, self.root / 'output')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / 'escape').exists())


class LinkerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='xtool linker ')
        self.root = Path(self.tmp.name)
        shutil.copy2(BIN / ('xtool-linker' + SUFFIX), self.root / ('ld64.lld' + SUFFIX))
        (self.root / 'orig').mkdir()
        for executable in (self.root / ('orig/ld64.lld' + SUFFIX), self.root / ('llvm-lib' + SUFFIX)):
            if os.name == 'nt':
                shutil.copy2(os.environ['XTOOL_NATIVE_TEST_CHILD'], executable)
                continue
            executable.write_text('#!/usr/bin/env python3\nimport json, sys\nprint(json.dumps(sys.argv[1:]))\nsys.exit(23)\n')
            executable.chmod(0o755)

    def tearDown(self):
        self.tmp.cleanup()

    def run_linker(self, args):
        return subprocess.run([self.root / ('ld64.lld' + SUFFIX), *args], capture_output=True, text=True, encoding='utf-8')

    def test_passthrough_and_exit_status(self):
        args = ['-o', 'space ü/output', '@a response file', 'an object.o', '', 'embedded "quote"', 'C:\\space path\\', 'backslash\\"quote', 'emoji 🔨']
        result = self.run_linker(args)
        self.assertEqual(result.returncode, 23)
        self.assertEqual(json.loads(result.stdout), args)

    @unittest.skipUnless(os.name == 'nt', 'Windows executable discovery')
    def test_bare_argv_zero_locates_companion_tools(self):
        args = ['-o', 'output with spaces']
        result = subprocess.run(['ld64.lld.exe', *args], executable=self.root / 'ld64.lld.exe',
                                cwd=self.root.parent, capture_output=True, text=True, encoding='utf-8')
        self.assertEqual(result.returncode, 23, result.stderr)
        self.assertEqual(json.loads(result.stdout), args)

    def test_relocatable_objects_use_apple_librarian(self):
        args = ['-r', '-filelist', 'file list', '-o', 'object output.o', '-dependency_info', 'dependency file']
        result = self.run_linker(args)
        self.assertEqual(result.returncode, 23)
        self.assertEqual(json.loads(result.stdout), ['-static', '-filelist', 'file list',
                                                   '-dependency_info', 'dependency file', '-o', 'object output.o'])

    def test_relocatable_response_files(self):
        args = ['-r', '-filelist', 'file list ü', '-dependency_info', 'dependency file', '-o', 'object output.o']
        content = subprocess.list2cmdline(args)
        for encoding in ('utf-8-sig', 'utf-16'):
            with self.subTest(encoding=encoding):
                response = self.root / 'link response.rsp'
                response.write_text(content, encoding=encoding)
                result = self.run_linker(['@' + str(response)])
                self.assertEqual(result.returncode, 23, result.stderr)
                self.assertEqual(json.loads(result.stdout), ['-static', '-filelist', 'file list ü',
                                                           '-dependency_info', 'dependency file', '-o', 'object output.o'])

    def test_cyclic_response_files_fail(self):
        response = self.root / 'cyclic.rsp'
        response.write_text('"@' + str(response) + '"')
        result = self.run_linker(['@' + str(response)])
        self.assertEqual(result.returncode, 2)

    def test_missing_argument_fails(self):
        result = self.run_linker(['-r', '-o'])
        self.assertEqual(result.returncode, 2)


if __name__ == '__main__':
    unittest.main()
