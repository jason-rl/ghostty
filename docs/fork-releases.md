# Fork releases and updates

The semantic ports come from Zed commits `f3db816fcd`, `f6afcbc377`,
`2ab3795ce7`, and `b345c2b3aa`. The build and packaging use Ghostty's Zig library,
Xcode app, and DMG conventions.

Only `.github/workflows/fork-release.yml` runs automatically in this fork.
Upstream automation is retained for manual dispatch. The fork workflow runs on
pushes to `main` in `jason-rl/ghostty`, and can also be dispatched manually.
It builds arm64 only, using Zig `ReleaseFast` (runtime optimization), Xcode
`Release`, Swift `-O` with whole-module and cross-module optimization, and full
Xcode link-time optimization. Debug symbols are packaged separately. There is
no release-speed shortcut or developer signing requirement.

The workflow publishes `Ghostty-aarch64.dmg`, `Ghostty-aarch64-dsym.zip`, and
`fork-release.json`. The version comes from `build.zig.zon`; each successful
publication replaces the `vX.Y.Z` release/tag and targets the exact source
commit. The app and manifest record that full commit. Builds are serialized.
GitHub may coalesce queued pushes while an earlier workflow is running.

Packaging signs nested code and the app ad hoc and checks its signature and
architecture. These builds are not notarized; the first installation follows
macOS's approval flow for software downloaded outside the App Store.

Packaged fork builds check the fork's latest GitHub release hourly using the
existing update settings and UI. A newer version is offered normally. For an
equal version, a different full commit is an update; the installed or already
staged commit is not offered again. Older versions are ignored. Source builds
without the fork packaging flag retain their existing updater behavior.

The custom installer downloads over HTTPS, verifies the release manifest's
SHA-256, checks the app's bundle ID, version, commit, architecture, and ad hoc
signature, then stages a sibling bundle on the same filesystem. Installation
waits until Ghostty has passed its normal quit confirmation and exited. The
helper retains the old bundle as a backup, replaces the app, and optionally
relaunches it. A failed replacement restores the old app. The next successful
launch removes the backup; a failed installation is reported on startup.
A non-writable application location produces an error instead of attempting
privilege escalation.

The manifest checksum detects mismatched or damaged assets. Release authenticity
relies on HTTPS and access to the fork's GitHub repository; it is not a substitute
for developer signing or notarization. Sparkle's signed installer is not used
for these ad hoc builds.

Local checks:

```sh
actionlint .github/workflows/fork-release.yml
python3 dist/fork/test-updater.py
zig build test-media
dist/fork/test-media.sh
```

The macOS release build additionally requires full Xcode with the Metal tools
and the Nix development environment. Build the core before the app:

```sh
nix develop -c zig build -Doptimize=ReleaseFast -Dstrip=false \
  -Demit-macos-app=false -Dxcframework-target=native
nix develop -c nu macos/build.nu --configuration Release --arch arm64 \
  --unsigned --optimize-runtime
python3 dist/fork/package.py
```

Publication is performed by the GitHub workflow after its build succeeds.
