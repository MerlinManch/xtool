"""Check native Xcode prerequisites before streaming an archive."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tests'))
import test_native_tools as fixtures


@unittest.skipUnless(os.name == 'nt', 'Windows symlink capability required')
class WindowsSymlinkPrerequisiteTests(unittest.TestCase):
    def test_capability_check_supports_long_unicode_paths_and_cleans_up(self):
        with tempfile.TemporaryDirectory(prefix='xtool symlink preflight ü ') as temp:
            root = Path(temp) / ('nested directory/' * 20)
            root.mkdir(parents=True)
            result = subprocess.run([fixtures.BIN / ('xtool-unxip' + fixtures.SUFFIX),
                                     '--check-symlinks', root], capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(b'symbolic-link creation: OK', result.stdout)
            self.assertEqual(list(root.iterdir()), [])

    def test_existing_files_and_links_are_untouched(self):
        with tempfile.TemporaryDirectory(prefix='xtool symlink preflight ü ') as temp:
            root = Path(temp)
            marker = root / 'file-link'
            marker.write_text('preserved')
            (root / 'directory-link').symlink_to(Path('absent'), target_is_directory=True)
            before = set(root.iterdir())
            result = subprocess.run([fixtures.BIN / ('xtool-unxip' + fixtures.SUFFIX),
                                     '--check-symlinks', root], capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(set(root.iterdir()), before)
            self.assertEqual(marker.read_text(), 'preserved')
            self.assertEqual(os.readlink(root / 'directory-link'), 'absent')


if __name__ == '__main__':
    unittest.main()
