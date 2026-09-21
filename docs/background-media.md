# Background media

Ghostty can draw a PNG, JPEG, GIF, local video, YouTube video, YouTube live
broadcast, or a live broadcast selected from Holodex behind terminal content.
The macOS Metal and Linux OpenGL renderers support the same settings. Splits
share a continuous background across the terminal area; native window chrome
and dialogs retain their normal appearance. Audio is disabled.

Media is disabled by default. Add settings to your normal Ghostty configuration
and reload it. Invalid settings or unavailable tools leave the normal background
visible; playback failures produce a diagnostic notification and a log entry.
A previously decoded frame remains visible while reconnecting.

## Examples

```ini
background-media-source = image
background-media-path = ~/Pictures/background.png
background-media-opacity = 0.2
background-media-fit = cover
```

For a local animation, change the source to `gif` or `video`:

```ini
background-media-source = video
background-media-path = ~/Movies/background.mp4
background-media-max-fps = 30
background-media-hardware-acceleration = auto
```

For a single recorded YouTube video:

```ini
background-media-source = youtube-video
background-media-url = https://www.youtube.com/watch?v=VIDEO_ID
background-media-cache-size-mb = 10240
```

Replace `VIDEO_ID` with an eleven-character video ID. HTTPS `youtu.be`, YouTube
watch, live, shorts, and embed URLs are supported. Playlist URLs, credentials in
URLs, other sites, and arbitrary downloader arguments are rejected. Use
`youtube-live` instead for a broadcast that is currently live.

For a scheduled `youtube-live` broadcast, Ghostty displays its artwork while
waiting for playback to become available. The cover uses the same opacity, fit,
and continuous split background as other media. Playback retries continue in the
background; the first live frame replaces the cover without a blank transition.
Artwork does not hide the original playback diagnostic or replace an already
playing stream. Failed artwork lookups retry at most once a minute, and a loaded
cover is reused while waiting. Artwork downloads are limited to 8 MiB and use
the existing bounded PNG/JPEG decoder. No additional configuration is needed.

For Holodex, list channel IDs in preference order:

```ini
background-media-source = holodex
background-media-channel = UCxxxxxxxxxxxxxxxxxxxxxx
background-media-channel = UCyyyyyyyyyyyyyyyyyyyyyy
```

Use **Set Holodex API Key** in the command palette to save a key. The input is
masked. macOS stores it in Keychain; Linux uses Secret Service through
`libsecret-1.so.0` and an unlocked keyring. **Remove Holodex API Key** deletes
that stored key. A stored key takes priority over `HOLODEX_API_KEY` in Ghostty's
launch environment. The environment fallback applies only when the credential
store successfully reports that no key exists. A locked or failed store does
not silently change credentials. Keys never enter configuration files,
decoder/downloader arguments, child environments, or diagnostic messages.

Holodex requests use the system libcurl with bounded timeouts and cancellation.
Ghostty checks live broadcasts once a minute, retains the current broadcast
while it is still live, then chooses the first configured live channel and its
most recently started broadcast. With no live match it retries automatically.

## Tools and settings

PNG and JPEG need no external decoder. GIF and video require `ffmpeg` and
`ffprobe`; YouTube and Holodex also require `yt-dlp`. The decoder must support
FFmpeg's `readrate_initial_burst` input option. Install
these tools with your package manager. Finder-launched apps also search
`/opt/homebrew/bin`, `/usr/local/bin`, `/usr/bin`, and `/bin`.

| Setting                                  | Default   | Meaning                                                                     |
| ---------------------------------------- | --------- | --------------------------------------------------------------------------- |
| `background-media-source`                | `none`    | `none`, `image`, `gif`, `video`, `youtube-video`, `youtube-live`, `holodex` |
| `background-media-path`                  | unset     | Absolute local path or a path beginning with `~/`                           |
| `background-media-url`                   | unset     | A single YouTube video URL                                                  |
| `background-media-channel`               | empty     | Repeatable Holodex channel ID, at most 50                                   |
| `background-media-opacity`               | `0.2`     | Opacity between 0 and 1                                                     |
| `background-media-fit`                   | `cover`   | `cover` crops; `contain` leaves margins                                     |
| `background-media-max-fps`               | `30`      | Frame-rate ceiling, 1–60                                                    |
| `background-media-max-height`            | unset     | Fixed decode height ceiling, 2–8192; unset follows visible viewports        |
| `background-media-hardware-acceleration` | `auto`    | Try FFmpeg hardware decoding, then software; `off` forces software          |
| `background-media-cache-size-mb`         | `10240`   | Total persistent rendition budget in MiB                                    |
| `background-media-ffmpeg-path`           | `ffmpeg`  | Decoder executable                                                          |
| `background-media-ffprobe-path`          | `ffprobe` | Metadata executable                                                         |
| `background-media-yt-dlp-path`           | `yt-dlp`  | YouTube resolver/downloader executable                                      |

Playback clocks continue while windows are unfocused. Identical sources and
playback settings share one player. The largest recently visible viewport
controls decode size, accounting for cropping and display scaling. Resolution
upgrades debounce for 500 ms; downgrades wait five seconds. A candidate decoder
loads while the current decoder keeps playing, and replaces it after its first
frame. No unbounded frame queue is kept. Video uploads use packed NV12 and GPU
color conversion; GIFs use RGBA to preserve transparency. Each renderer's
swap-chain frame owns a reusable upload texture. Unchanged frames do not cause
a new terminal render. Selected text and other explicit UI highlights retain
their normal backgrounds; ordinary terminal cell backgrounds are softened.

## Cache

Recorded YouTube renditions live in
`~/Library/Caches/ghostty/background-media` on macOS and
`$XDG_CACHE_HOME/ghostty/background-media` (or `~/.cache/ghostty/background-media`)
on Linux. Local media and live broadcasts are not cached.

On a cache miss, playback streams immediately while a separate video-only
download fills the cache. This uses two network transfers during the first
download. Once complete, a candidate switches playback to the cached file at
the current position. A completed rendition is also reused without contacting
YouTube when that source is next opened. Shared file leases allow other Ghostty processes to
read completed entries and prevent active entries from being evicted. A global
lock protects byte accounting and eviction. Partial downloads count toward the
budget; incomplete or size-mismatched entries are never accepted as completed
videos. Least-recently-used inactive renditions are evicted first. If every
remaining rendition is leased, the download stops instead of exceeding the
budget. You can remove inactive cache files while Ghostty is closed.

## Verification and profiling

Run `zig build test-media` for configuration, key validation, player ownership,
cache budget, shared-lease, corruption, and offline-lookup tests. Run
`dist/fork/test-media.sh` with FFmpeg installed for a generated one-second video
that loops through downscaling and upscaling. It also checks the streamed-to-cache
handoff, offline reopening, and scheduled-cover-to-live transition with local
resolver fixtures. A loopback HTTP server checks artwork downloads and response
limits. Neither command accesses YouTube or Holodex. Set `ZIG` to select a Zig
executable for the script.

For a manual resource comparison, use the same window size with media disabled,
a local video, and a live source. Observe Ghostty and its FFmpeg/yt-dlp children
with Activity Monitor or `top`; repeat while typing, splitting, resizing, and
switching focus. Media workers use background priority, FFmpeg uses two decoder
threads and one filter thread, and upload memory is bounded by the frame limit
and swap-chain length. Network playback still depends on the installed
YouTube extractor and the source's availability.
