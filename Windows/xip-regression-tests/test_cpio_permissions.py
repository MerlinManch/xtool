"""Xcode CPIO hardlink permissions and payload ordering on native Windows."""
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tests'))
import test_native_tools as fixtures


class XcodeCPIOPermissionsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='xtool CPIO permissions ü ')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.count = 0

    def extract_pair(self, first, second, mode, names):
        directory = 'Xcode.app/usr/share/man/man3/'
        archive = (fixtures.cpio_entry(directory + names[0], first,
                                       mode=stat.S_IFREG | mode, inode=2, links=2)
                   + fixtures.cpio_entry(directory + names[1], second,
                                         mode=stat.S_IFREG | mode, inode=2, links=2)
                   + fixtures.cpio_entry('TRAILER!!!', inode=0))
        source = self.root / 'Xcode.xip'
        source.write_bytes(fixtures.xar(fixtures.pbzx(archive)))
        self.count += 1
        output = self.root / f'output {self.count}'
        result = subprocess.run([fixtures.BIN / ('xtool-unxip' + fixtures.SUFFIX), source, output],
                                capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        a, b = (output / directory / name for name in names)
        expected = second or first
        self.assertEqual(a.read_bytes(), expected)
        self.assertEqual(b.read_bytes(), expected)
        self.assertTrue(os.path.samefile(a, b))
        self.assertEqual(set(os.listdir(a.parent)), set(names))
        if os.name == 'nt' and not mode & 0o200:
            self.assertFalse(a.stat().st_mode & stat.S_IWRITE, 'Read-only archive mode was lost')
        sdk = self.root / f'SDK links {self.count}'
        sdk.mkdir()
        installed = sdk / 'header.h'
        os.link(a, installed)
        self.assertTrue(os.path.samefile(a, installed))
        self.assertEqual(installed.read_bytes(), expected)

    def test_read_only_manpages_with_data_in_either_link(self):
        for mode in (0o444, 0o644):
            for data_first in (True, False):
                for names in (('first.3', 'second.3'), ('circleq_init.3', 'CIRCLEQ_INIT.3')):
                    with self.subTest(mode=oct(mode), data_first=data_first, names=names):
                        self.extract_pair(b'manpage' if data_first else b'',
                                          b'' if data_first else b'manpage', mode, names)

    def test_read_only_hardlinks_with_payload_in_every_entry(self):
        for names in (('first.3', 'second.3'), ('circleq_init.3', 'CIRCLEQ_INIT.3')):
            with self.subTest(names=names):
                self.extract_pair(b'first payload', b'last payload', 0o444, names)


if __name__ == '__main__':
    unittest.main()
