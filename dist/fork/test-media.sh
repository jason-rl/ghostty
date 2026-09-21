#!/bin/sh
# Uses generated fixtures and a loopback HTTP server; no external services.
set -eu
fixture_dir=$(mktemp -d)
server_pid=
cleanup() {
    if [ -n "$server_pid" ]; then kill "$server_pid" 2>/dev/null || true; fi
    rm -rf "$fixture_dir"
}
trap cleanup EXIT HUP INT TERM
ffmpeg -hide_banner -loglevel error -f lavfi -i testsrc2=size=320x180:rate=30 \
    -t 1 -an -c:v mpeg4 "$fixture_dir/loop.mp4"
python3 - "$fixture_dir" <<'PYTOOLS'
import json, os, pathlib, shutil, struct, sys, zlib
root = pathlib.Path(sys.argv[1])
cache = root / "cache"
cache.mkdir()
video = str(root / "loop.mp4")
ffmpeg = shutil.which("ffmpeg")
downloader = root / "yt-dlp"
downloader.write_text(f'''#!/usr/bin/env python3
import json, pathlib, sys, time
if "--dump-json" in sys.argv:
    with open({str(cache / "metadata-calls")!r}, "ab") as calls: calls.write(b"x")
    print(json.dumps(dict(url="https://example.invalid/video", width=320, height=180, duration=1, format_id="test", is_live=False)))
else:
    time.sleep(1)
    sys.stdout.buffer.write(pathlib.Path({video!r}).read_bytes())
''')
decoder = root / "ffmpeg"
decoder.write_text(f'''#!/usr/bin/env python3
import os, pathlib, sys
args = sys.argv[1:]
index = args.index("-i") + 1
if args[index] == "https://example.invalid/video":
    args[index] = {video!r}
else:
    pathlib.Path({str(cache / "cached-playback")!r}).touch()
os.execv({ffmpeg!r}, [{ffmpeg!r}] + args)
''')
for tool in (downloader, decoder): tool.chmod(0o755)

# A red PNG, generated with the standard library so artwork needs no extra tools.
def chunk(kind, data):
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
cover = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 32, 32, 8, 6, 0, 0, 0))
cover += chunk(b"IDAT", zlib.compress((b"\x00" + bytes([255, 0, 0, 255]) * 32) * 32)) + chunk(b"IEND", b"")
(root / "cover.png").write_bytes(cover)
artwork = root / "artwork-yt-dlp"
artwork.write_text(f'''#!/usr/bin/env python3
import json, pathlib, sys
root = pathlib.Path({str(root)!r})
if "--ignore-no-formats-error" in sys.argv:
    with (root / "artwork-calls").open("ab") as calls: calls.write(b"x")
    print(json.dumps(dict(id="abcdefghijk", live_status="is_upcoming", thumbnail=(root / "server-url").read_text() + "/cover.png")))
elif (root / "live").exists():
    print(json.dumps(dict(url="https://example.invalid/video", width=320, height=180, is_live=True)))
else:
    sys.exit(1)
''')
artwork.chmod(0o755)
(root / "server.py").write_text('''
import http.server, pathlib, sys, time
root = pathlib.Path(sys.argv[1])
class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_GET(self):
        if self.headers.get("X-APIKEY"):
            self.send_error(400)
            return
        if self.path == "/slow":
            self.send_response(200)
            self.end_headers()
            time.sleep(20)
            return
        if self.path == "/redirect-file":
            self.send_response(302)
            self.send_header("Location", "file:///etc/passwd")
            self.end_headers()
            return
        if self.path == "/cover.png":
            with (root / "cover-requests").open("ab") as calls: calls.write(b"x")
            body = (root / "cover.png").read_bytes()
        elif self.path == "/too-large":
            body = b"x" * (8 * 1024 * 1024 + 1)
        else:
            self.send_error(404)
            return
        self.send_response(200)
        self.end_headers()
        try: self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError): pass
server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
(root / "server-url").write_text("http://127.0.0.1:" + str(server.server_port))
server.serve_forever()
''')
PYTOOLS
python3 "$fixture_dir/server.py" "$fixture_dir" &
server_pid=$!
attempt=0
while [ ! -f "$fixture_dir/server-url" ]; do
    kill -0 "$server_pid"
    attempt=$((attempt + 1))
    [ "$attempt" -lt 100 ]
    sleep 0.1
done
GHOSTTY_MEDIA_TEST_ARTWORK_ROOT="$fixture_dir" \
GHOSTTY_MEDIA_TEST_ARTWORK_URL="$(cat "$fixture_dir/server-url")" \
GHOSTTY_MEDIA_TEST_ARTWORK_YT_DLP="$fixture_dir/artwork-yt-dlp" \
GHOSTTY_MEDIA_TEST_CACHE="$fixture_dir/cache" \
GHOSTTY_MEDIA_TEST_YT_DLP="$fixture_dir/yt-dlp" \
GHOSTTY_MEDIA_TEST_FFMPEG="$fixture_dir/ffmpeg" \
GHOSTTY_MEDIA_TEST_VIDEO="$fixture_dir/loop.mp4" "${ZIG:-zig}" build test-media \
    -Dxcframework-target=native -Demit-macos-app=false
