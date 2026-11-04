#!/usr/bin/env python3
"""Stage build inputs without a Git worktree or iCloud-mutated compiler inputs."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys


def stage(repository, destination):
    repository, destination = Path(repository), Path(destination)
    destination.mkdir(parents=True, exist_ok=True)
    listing = subprocess.check_output(
        ['git', '-C', str(repository), 'ls-files', '-z', '--cached', '--others', '--exclude-standard'],
        timeout=60,
    )
    names = sorted(set(os.fsdecode(name) for name in listing.split(b'\0') if name))
    manifest = destination / '.otto-source-manifest.json'
    # Snapshots staged before the rename keep their manifest under the old name.
    legacy_manifest = destination / '.muse-source-manifest.json'
    source_manifest = manifest if manifest.exists() else legacy_manifest
    previous = json.loads(source_manifest.read_text()) if source_manifest.exists() else []
    cached = previous if isinstance(previous, dict) else {}
    present = {}

    def fingerprint(path):
        value = path.lstat()
        return [value.st_mtime_ns, value.st_size, value.st_mode]

    for name in names:
        relative = Path(name)
        if relative.is_absolute() or '..' in relative.parts or relative.parts[0] == '.build':
            raise ValueError(f'Unsafe build input: {name}')
        source, target = repository / relative, destination / relative
        if not source.exists() and not source.is_symlink():
            continue  # A tracked deletion must also disappear from the snapshot.
        if source.is_dir() and not source.is_symlink():
            raise ValueError(f'Build snapshots require ordinary files, found directory: {name}')
        source_stamp = fingerprint(source)
        old = cached.get(name)
        if old and old['source'] == source_stamp and (target.exists() or target.is_symlink()):
            if old['target'] == fingerprint(target):
                present[name] = old
                continue
        print(f'Staging build input: {name}', flush=True)
        target.parent.mkdir(parents=True, exist_ok=True)
        if source.is_symlink():
            link = os.readlink(source)
            if target.is_symlink() and os.readlink(target) == link:
                present[name] = {'source': source_stamp, 'target': fingerprint(target)}
                continue
            if target.exists() or target.is_symlink():
                target.unlink()
            target.symlink_to(link)
        else:
            # Reading happens before SwiftPM starts, under the wrapper's timeout. Keep unchanged
            # snapshot mtimes stable so incremental builds remain useful.
            data = source.read_bytes()
            if target.is_symlink():
                target.unlink()
            if not target.exists() or target.read_bytes() != data:
                temporary = target.with_name(target.name + '.otto-copy')
                temporary.write_bytes(data)
                temporary.replace(target)
            shutil.copymode(source, target)
        if fingerprint(source) != source_stamp:
            raise OSError(f'Build input changed while being staged: {name}; retry the build')
        present[name] = {'source': source_stamp, 'target': fingerprint(target)}
    for name in set(previous) - set(present):
        target = destination / name
        if target.is_file() or target.is_symlink():
            target.unlink()
    manifest.write_text(json.dumps(present))
    if legacy_manifest.exists():
        legacy_manifest.unlink()
    print(f'Frozen {len(present)} build inputs in {destination}', flush=True)


if __name__ == '__main__':
    try:
        stage(sys.argv[1], sys.argv[2])
    except subprocess.TimeoutExpired:
        sys.exit('Could not read the worktree Git index within 60 seconds. '
                 'Download the worktree from iCloud and retry; SwiftPM was not started.')
    except OSError as error:
        sys.exit(f'Could not freeze build inputs: {error}. SwiftPM was not started.')
    os.execv(sys.argv[3], sys.argv[3:])
