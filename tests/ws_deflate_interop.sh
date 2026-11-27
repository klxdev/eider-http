#!/bin/sh
# permessage-deflate against python3's zlib as an independent DEFLATE (tests/ws_deflate_interop.py), over loopback:
#
#   sh tests/ws_deflate_interop.sh <dir with the built wssrv>
#
# Prints `ok   ws deflate interop: <case>` or `FAIL ...`; `skip` without python3; exits 1 on a failure.
bin=$1
[ -x "$bin/wssrv" ] || { echo "FAIL ws deflate interop: $bin has no wssrv"; exit 1; }
if ! command -v python3 >/dev/null 2>&1; then echo "skip ws deflate interop: no python3"; exit 0; fi
here=$(cd "$(dirname "$0")/.." && pwd -P)
T=$(mktemp -d)
trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$T"' EXIT
"$bin/wssrv" > "$T/srv.log" 2>&1 &
i=0
while [ $i -lt 100 ] && ! grep -q '^listening' "$T/srv.log" 2>/dev/null; do sleep 0.1; i=$((i + 1)); done
port=$(sed -n 's/^listening \([0-9]*\).*/\1/p' "$T/srv.log" | head -1)
[ -n "$port" ] || { echo "FAIL ws deflate interop: the Eider server did not start"; cat "$T/srv.log"; exit 1; }
python3 -I "$here/tests/ws_deflate_interop.py" "$port"
