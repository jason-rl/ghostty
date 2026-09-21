#!/usr/bin/env python3
"""Exercise the installer against temporary fake bundles, never the installed app."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

HELPER = Path(__file__).with_name('update.sh').resolve()


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='ghostty installer ')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.destination = self.root / 'Ghostty with spaces.app'
        self.staged = self.root / '.Ghostty-update-test.app'
        self.backup = self.root / '.Ghostty-backup-test.app'
        for app, marker in [(self.destination, 'old'), (self.staged, 'new')]:
            (app / 'Contents').mkdir(parents=True)
            (app / 'Contents/version').write_text(marker)

    def install(self, env=None):
        # A reaped child PID prevents the helper from waiting on this test runner.
        child = subprocess.Popen(['/usr/bin/true'])
        child.wait()
        return subprocess.run(['/bin/sh', str(HELPER), str(child.pid),
                               str(self.staged), str(self.destination), str(self.backup), 'no'],
                              env=env, capture_output=True, timeout=10)

    def test_replacement_retains_backup(self):
        self.assertEqual(self.install().returncode, 0)
        self.assertEqual((self.destination / 'Contents/version').read_text(), 'new')
        self.assertEqual((self.backup / 'Contents/version').read_text(), 'old')
        self.assertFalse(self.staged.exists())

    def test_failed_move_rolls_back(self):
        # Inject failure only for the second rename; the real filesystem still
        # exercises the original rename and rollback with space-containing paths.
        tools = self.root / 'tools'
        tools.mkdir()
        move = tools / 'mv'
        move.write_text('#!/bin/sh\ncase "$1" in *Ghostty-update*) exit 1;; esac\nexec /bin/mv "$@"\n')
        move.chmod(0o755)
        result = self.install(dict(os.environ, PATH=f'{tools}:/usr/bin:/bin'))
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.destination / 'Contents/version').read_text(), 'old')
        self.assertTrue(self.staged.exists())
        self.assertFalse(self.backup.exists())

    def test_existing_backup_is_never_overwritten(self):
        self.backup.mkdir()
        self.assertNotEqual(self.install().returncode, 0)
        self.assertEqual((self.destination / 'Contents/version').read_text(), 'old')


if __name__ == '__main__':
    unittest.main()
