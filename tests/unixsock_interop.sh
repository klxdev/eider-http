#!/bin/sh
# Interoperability of http/unixsock and http/proxyproto with other implementations, over a unix socket in a temporary
# directory and loopback:
#
#   sh tests/unixsock_interop.sh <dir with the built usrv>
#
#   curl --unix-socket     against the Eider server: GET, POST, a 1 MiB body, the Docker-style `http://localhost` Host, HTTP/2 prior
#                          knowledge over the socket, the socket file's mode
#   python3 (stdlib)       sends PROXY protocol v1 and v2 headers it builds itself (an independent writer: the CRC32c TLV, ALPN
#                          and authority TLVs included) to the Eider server on TCP, and a header the server must refuse
#
# Prints `ok   unixsock interop: <case>` or `FAIL ...`; `skip` for a tool that is not installed; exits 1 on a failure.
here=$(cd "$(dirname "$0")/.." && pwd -P)
bin=$1
[ -x "$bin/usrv" ] || { echo "FAIL unixsock interop: $bin has no usrv"; exit 1; }
T=$(mktemp -d /tmp/eider-uxi.XXXXXX)
trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$T"' EXIT
fail=0

check() { # name, output file, pattern...
  name=$1; out=$2; shift 2
  for pat in "$@"; do
    if ! grep -q -- "$pat" "$out"; then
      echo "FAIL unixsock interop: $name (missing: $pat)"; sed 's/^/    | /' "$out" | head -20; fail=1; return
    fi
  done
  echo "ok   unixsock interop: $name"
}

"$bin/usrv" "$T/s.sock" 640 > "$T/srv.log" 2>&1 &
i=0
while [ $i -lt 100 ] && ! grep -q listening "$T/srv.log" 2>/dev/null; do sleep 0.1; i=$((i + 1)); done
grep -q listening "$T/srv.log" || { echo "FAIL unixsock interop: the Eider server did not start"; cat "$T/srv.log"; exit 1; }
port=$(sed -n 's/^listening \([0-9]*\).*/\1/p' "$T/srv.log" | head -1)

if command -v curl >/dev/null 2>&1; then
  curl -sS --max-time 20 --unix-socket "$T/s.sock" http://localhost/hello > "$T/o" 2>&1
  check "curl GET" "$T/o" "hello over a unix socket"
  curl -sS --max-time 20 --unix-socket "$T/s.sock" -d 'a body from curl' http://localhost/echo > "$T/o" 2>&1
  check "curl POST" "$T/o" "a body from curl"
  head -c 1048576 /dev/zero | tr '\0' 'x' > "$T/big"
  curl -sS --max-time 20 --unix-socket "$T/s.sock" --data-binary @"$T/big" http://localhost/echo -o "$T/big.out" 2>&1
  if cmp -s "$T/big" "$T/big.out"; then echo "ok   unixsock interop: curl 1 MiB POST echoed intact"; else echo "FAIL unixsock interop: curl 1 MiB POST"; fail=1; fi
  curl -sS --max-time 20 --unix-socket "$T/s.sock" http://docker.example/peer > "$T/o" 2>&1
  check "curl Host header and unix peer" "$T/o" "peer=unix:" "host=docker.example"
  if curl -V | grep -q nghttp2; then
    curl -sS --max-time 20 --unix-socket "$T/s.sock" --http2-prior-knowledge -w '\nversion=%{http_version}\n' http://localhost/hello > "$T/o" 2>&1
    check "curl h2c over the unix socket" "$T/o" "hello over a unix socket" "version=2"
  else
    echo "skip unixsock interop: curl without HTTP/2"
  fi
  mode=$(stat -c %a "$T/s.sock" 2>/dev/null)
  if [ "$mode" = "640" ]; then echo "ok   unixsock interop: socket file mode 640"; else echo "FAIL unixsock interop: socket file mode is '$mode', not 640"; fail=1; fi
else
  echo "skip unixsock interop: no curl on the PATH"
fi

if command -v python3 >/dev/null 2>&1; then
  python3 -I - "$port" > "$T/py.out" 2>&1 <<'PY'
import socket, struct, sys

port = int(sys.argv[1])

def crc32c(data):
    crc = 0xFFFFFFFF
    for b in data:
        crc ^= b
        for _ in range(8):
            crc = (crc >> 1) ^ (0x82F63B78 if crc & 1 else 0)
    return crc ^ 0xFFFFFFFF

SIG = b"\r\n\r\n\x00\r\nQUIT\n"

def v2(src, sport, dst, dport, tlvs=b"", crc=False):
    body = socket.inet_aton(src) + socket.inet_aton(dst) + struct.pack("!HH", sport, dport) + tlvs
    if crc:
        body += b"\x03\x00\x04\x00\x00\x00\x00"
    hdr = SIG + b"\x21\x11" + struct.pack("!H", len(body)) + body
    if crc:
        hdr = hdr[:-4] + struct.pack("!I", crc32c(hdr))
    return hdr

def tlv(t, v):
    return bytes([t]) + struct.pack("!H", len(v)) + v

def ask(pre, tail=b""):
    s = socket.create_connection(("127.0.0.1", port), timeout=10)
    s.sendall(pre + b"GET /peer HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n" + tail)
    data = b""
    try:
        while True:
            b = s.recv(65536)
            if not b:
                break
            data += b
    except (ConnectionResetError, socket.timeout):
        pass
    s.close()
    return data.decode("latin-1")

print("v1:", ask(b"PROXY TCP4 203.0.113.5 192.0.2.1 5555 80\r\n").split("\r\n\r\n", 1)[-1])
print("v1 tcp6:", ask(b"PROXY TCP6 2001:db8::5 2001:db8::1 5555 80\r\n").split("\r\n\r\n", 1)[-1])
print("v2:", ask(v2("198.51.100.6", 6666, "192.0.2.1", 80)).split("\r\n\r\n", 1)[-1])
print("v2 tlv crc:", ask(v2("198.51.100.7", 7777, "192.0.2.1", 80, tlv(1, b"h2") + tlv(2, b"shop.example"), crc=True)).split("\r\n\r\n", 1)[-1])
bad = bytearray(v2("198.51.100.8", 1, "192.0.2.1", 80, tlv(2, b"x"), crc=True)); bad[20] ^= 1
print("v2 bad crc:", repr(ask(bytes(bad))))
print("no header:", repr(ask(b"")))
print("garbage:", repr(ask(b"PROXY TCP4 nonsense\r\n")))
PY
  check "python PROXY v1" "$T/py.out" "v1: peer=203.0.113.5:5555 host=x proxy_peer=127.0.0.1:"
  check "python PROXY v1 over IPv6" "$T/py.out" "v1 tcp6: peer=\[2001:db8:0:0:0:0:0:5\]:5555"
  check "python PROXY v2" "$T/py.out" "v2: peer=198.51.100.6:6666"
  check "python PROXY v2 with TLVs and CRC32c" "$T/py.out" "peer=198.51.100.7:7777" "alpn=h2 authority=shop.example"
  check "python PROXY v2 bad CRC dropped" "$T/py.out" "v2 bad crc: ''"
  check "python no header dropped" "$T/py.out" "no header: ''"
  check "python garbage header dropped" "$T/py.out" "garbage: ''"
else
  echo "skip unixsock interop: no python3 on the PATH"
fi

curl -sS --max-time 5 --unix-socket "$T/s.sock" http://localhost/quit >/dev/null 2>&1
wait
[ $fail = 0 ]
