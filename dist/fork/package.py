#!/usr/bin/env python3
"""Package an arm64 Ghostty Release build without developer credentials."""
import hashlib
import json
import pathlib
import plistlib
import re
import shutil
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[2]


def run(*args):
    return subprocess.check_output(args, cwd=ROOT, text=True).strip()


def main():
    app = ROOT / 'macos/build/Release/Ghostty.app'
    out = ROOT / 'zig-out/fork-release'
    out.mkdir(parents=True, exist_ok=True)
    version = re.search(r'\.version = "([0-9]+\.[0-9]+\.[0-9]+)"',
                        (ROOT / 'build.zig.zon').read_text()).group(1)
    commit = run('git', 'rev-parse', 'HEAD')
    build = run('git', 'rev-list', '--count', 'HEAD')
    plist = app / 'Contents/Info.plist'
    info = plistlib.loads(plist.read_bytes())
    info.update(CFBundleShortVersionString=version, CFBundleVersion=build,
                GhosttyCommit=commit, GhosttyForkUpdates=True,
                SUEnableAutomaticChecks=True)
    plist.write_bytes(plistlib.dumps(info))
    helper = app / 'Contents/Resources/fork-update.sh'
    shutil.copy2(ROOT / 'dist/fork/update.sh', helper)
    # Nested code must be signed before the enclosing app. Ad hoc signing needs no key.
    def is_code(path):
        if path.is_symlink():
            return False
        if path.is_dir():
            return path.suffix in {'.app', '.xpc', '.framework', '.plugin'}
        if not path.is_file():
            return False
        # Include standalone helpers such as Sparkle's Autoupdate binary.
        with path.open('rb') as source:
            return source.read(4) in {
                b'\xcf\xfa\xed\xfe', b'\xfe\xed\xfa\xcf',
                b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca',
                b'\xca\xfe\xba\xbf', b'\xbf\xba\xfe\xca',
            }

    nested = sorted((p for p in app.rglob('*') if is_code(p)),
                    key=lambda p: len(p.parts), reverse=True)
    for path in nested:
        run('codesign', '--force', '--sign', '-', str(path))
    run('codesign', '--force', '--sign', '-', '--entitlements',
        str(ROOT / 'macos/GhosttyReleaseLocal.entitlements'), str(app))
    run('codesign', '--verify', '--deep', '--strict', str(app))
    assert run('lipo', '-archs', str(app / 'Contents/MacOS/ghostty')) == 'arm64'
    staging = ROOT / 'zig-out/fork-dmg'
    if staging.exists():
        shutil.rmtree(staging)
    staging.mkdir()
    run('ditto', str(app), str(staging / 'Ghostty.app'))
    (staging / 'Applications').symlink_to('/Applications')
    dmg = out / 'Ghostty-aarch64.dmg'
    run('hdiutil', 'create', '-ov', '-format', 'UDZO', '-volname', 'Ghostty',
        '-srcfolder', str(staging), str(dmg))
    run('hdiutil', 'verify', str(dmg))
    symbols = app.with_name('Ghostty.app.dSYM')
    if not symbols.exists():
        run('dsymutil', str(app / 'Contents/MacOS/ghostty'), '-o', str(symbols))
    run('ditto', '-c', '-k', '--keepParent', str(symbols),
        str(out / 'Ghostty-aarch64-dsym.zip'))
    with dmg.open('rb') as source:
        checksum = hashlib.file_digest(source, 'sha256').hexdigest()
    manifest = dict(version=version, commit=commit, build=build, sha256=checksum)
    (out / 'fork-release.json').write_text(json.dumps(manifest, indent=2) + '\n')


if __name__ == '__main__':
    main()
