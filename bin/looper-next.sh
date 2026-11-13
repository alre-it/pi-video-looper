#!/bin/sh
# Tell the running looper's mpv to play the next video (or the previous one
# with "prev"). Needs root or the tv user: the socket belongs to tv.
set -eu
cmd=playlist-next
[ "${1:-}" = prev ] && cmd=playlist-prev
exec python3 - "${IPC_SOCKET:-/run/pi-video-looper/mpv.sock}" "$cmd" <<'PY'
import json, socket, sys
path, cmd = sys.argv[1], sys.argv[2]
s = socket.socket(socket.AF_UNIX)
s.settimeout(3)
s.connect(path)
s.sendall(json.dumps({"command": [cmd]}).encode() + b"\n")
reply = s.recv(4096).decode(errors="replace")
print(reply.splitlines()[0] if reply else "no reply")
PY
