#!/usr/bin/env python3
import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import sys
sys.dont_write_bytecode = True

spec = importlib.util.spec_from_file_location('snapshot', Path(__file__).with_name('otto-swift-snapshot.py'))
snapshot = importlib.util.module_from_spec(spec)
spec.loader.exec_module(snapshot)


class SnapshotTests(unittest.TestCase):
    def test_unchanged_inputs_do_not_need_rehydration(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            repo, dest = root / 'repo', root / 'frozen.nosync'
            repo.mkdir()
            subprocess.run(['git', 'init', '-q', str(repo)], check=True)
            (repo / 'stable.swift').write_text('original')
            snapshot.stage(repo, dest)
            with patch.object(Path, 'read_bytes', side_effect=AssertionError('Unchanged input was read')):
                snapshot.stage(repo, dest)
            (dest / 'stable.swift').write_text('tampered')
            snapshot.stage(repo, dest)
            self.assertEqual((dest / 'stable.swift').read_text(), 'original')

    def test_dirty_untracked_deleted_and_unchanged_inputs(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            repo, dest = root / 'repo', root / 'frozen.nosync'
            repo.mkdir()
            subprocess.run(['git', 'init', '-q', str(repo)], check=True)
            for name in ['changed.swift', 'deleted.swift', 'stable.swift']:
                (repo / name).write_text('original')
            subprocess.run(['git', '-C', str(repo), 'add', '.'], check=True)
            snapshot.stage(repo, dest)
            original_mtime = (dest / 'stable.swift').stat().st_mtime_ns
            (repo / 'changed.swift').write_text('edited')
            (repo / 'deleted.swift').unlink()
            (repo / 'new.swift').write_text('new')
            snapshot.stage(repo, dest)
            self.assertEqual((dest / 'changed.swift').read_text(), 'edited')
            self.assertEqual((dest / 'new.swift').read_text(), 'new')
            self.assertFalse((dest / 'deleted.swift').exists())
            self.assertEqual((dest / 'stable.swift').stat().st_mtime_ns, original_mtime)
            self.assertFalse((dest / '.git').exists())
            (repo / 'changed.swift').write_text('changed during build')
            self.assertEqual((dest / 'changed.swift').read_text(), 'edited')


    def test_tracked_symlink_to_a_directory_is_staged_as_a_link(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            repo, dest = root / 'repo', root / 'frozen.nosync'
            (repo / '.agents' / 'skills' / 'design').mkdir(parents=True)
            subprocess.run(['git', 'init', '-q', str(repo)], check=True)
            (repo / '.agents' / 'skills' / 'design' / 'SKILL.md').write_text('skill')
            (repo / '.claude' / 'skills').mkdir(parents=True)
            os.symlink('../../.agents/skills/design', repo / '.claude' / 'skills' / 'design')
            subprocess.run(['git', '-C', str(repo), 'add', '.'], check=True)
            snapshot.stage(repo, dest)
            staged = dest / '.claude' / 'skills' / 'design'
            self.assertTrue(staged.is_symlink())
            self.assertEqual(os.readlink(staged), '../../.agents/skills/design')
            self.assertEqual((staged / 'SKILL.md').read_text(), 'skill')
            snapshot.stage(repo, dest)
            self.assertTrue(staged.is_symlink())

if __name__ == '__main__':
    unittest.main()
