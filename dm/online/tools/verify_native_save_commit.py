#!/usr/bin/env python3
"""Build and run real native Swift/C save-commit integration on synthetic files.

Requires macOS with Xcode. No game assets, account, device, network or original
image is read. Build artifacts stay in the explicit scratch directory.
"""
import argparse
import os
import subprocess
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--scratch', required=True, type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    scratch = args.scratch.resolve()
    scratch.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env['TMPDIR'] = str(scratch)
    sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], env=env, text=True).strip()
    inputs = [root / 'online/tools/SaveCommitIntegration/driver.c', root / 'online/tools/SaveCommitIntegration/cloud_stubs.c',
              root / 'host/tests/t_fs_stub.c', root / 'host/dm_i18n.c', root / 'ios/Sources/cloud_ios.m']
    objects = []
    for source in inputs:
        output = scratch / (source.stem + '.o')
        objc = ['-fobjc-arc', '-fblocks'] if source.suffix == '.m' else []
        subprocess.run(['xcrun', '--sdk', 'macosx', 'clang', '-O1', *objc, '-Wno-unused-function', '-I', str(root / 'host'),
                        '-isysroot', sdk, '-c', str(source), '-o', str(output)], env=env, check=True, timeout=60)
        objects.append(str(output))
    sources = sorted(map(str, (root / 'online/Sources/ReimaginedClient').glob('*.swift')))
    executable = scratch / 'native-save-commit-check'
    subprocess.run(['xcrun', '--sdk', 'macosx', 'swiftc', '-O', '-sdk', sdk, '-module-name', 'NativeSaveCommitCheck',
                    '-import-objc-header', str(root / 'online/tools/SaveCommitIntegration/driver.h'), *sources,
                    str(root / 'ios/Sources/dm_online_tables.swift'), str(root / 'online/tools/SaveCommitIntegration/main.swift'),
                    *objects, '-framework', 'Security', '-framework', 'Network', '-o', str(executable)], env=env, check=True, timeout=180)
    subprocess.run([str(executable), str(scratch)], env=env, check=True, timeout=45)
    subprocess.run([str(executable), str(scratch), '--readback-failure'], env=env, check=True, timeout=45)
    subprocess.run([str(executable), str(scratch), '--late-namespace'], env=env, check=True, timeout=45)
    subprocess.run([str(executable), str(scratch), '--detach'], env=env, check=True, timeout=45)
    subprocess.run([str(executable), str(scratch), '--server-owned'], env=env, check=True, timeout=45)


if __name__ == '__main__':
    main()
