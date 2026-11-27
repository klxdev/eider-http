#!/bin/sh
# Interoperability of http/cookie and http/pool with python3's standard library, over loopback:
#
#   sh tests/pool_interop.sh <dir with the built pool_interop>
#
#   http.cookies           reads the Set-Cookie lines http/cookie builds (name, value, Path, Domain, Max-Age, Secure, HttpOnly, SameSite)
#   http.server            serves redirects (302, 307), cookies, gzip and keep-alive to the Eider client (http/pool)
#
# Prints `ok   pool interop: <case>` or `FAIL pool interop: <case>`; `skip` without python3; exits 1 on a failure.
here=$(cd "$(dirname "$0")/.." && pwd -P)
bin=$1
command -v python3 >/dev/null 2>&1 || { echo "skip pool interop: no python3"; exit 0; }
[ -x "$bin/pool_interop" ] || { echo "FAIL pool interop: $bin has no pool_interop"; exit 1; }
T=$(mktemp -d)
trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$T"' EXIT
fail=0
"$bin/pool_interop" cookies > "$T/lines" 2>&1
python3 -I - "$T/lines" <<'PY' > "$T/cookies.out" 2>&1 || fail=1
import sys
from http.cookies import SimpleCookie
lines = open(sys.argv[1]).read().splitlines()
def one(l):
    c = SimpleCookie(); c.load(l); return list(c.values())[0]
a, b, c, d = [one(l) for l in lines[:4]]
assert (a.key, a.value, a['path'], bool(a['secure']), bool(a['httponly'])) == ('SID', '31d4d96e407aad42', '/', True, True), lines[0]
assert (b.key, b.value, b['domain'], b['path'], b['max-age'], b['samesite']) == ('lang', 'en-US', 'example.com', '/x', '3600', 'Strict'), lines[1]
assert (c.key, c['expires']) == ('old', 'Sun, 06 Nov 1994 08:49:37 GMT'), lines[2]
assert (d.key, d.coded_value, d['samesite']) == ('quoted', '"ab"', 'Lax'), lines[3]
print("fine")
PY
if grep -q fine "$T/cookies.out"; then echo "ok   pool interop: Set-Cookie read by python http.cookies"; else echo "FAIL pool interop: Set-Cookie"; cat "$T/cookies.out" "$T/lines" | head; fail=1; fi
cat > "$T/srv.py" <<'PY'
import gzip, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass
    def send(self, code, body=b"", headers=()):
        self.send_response(code)
        for k, v in headers: self.send_header(k, v)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def do_GET(self):
        n = int(self.headers.get("Content-Length") or 0)
        if n: self.rfile.read(n)
        p = self.path
        if p == "/hello": self.send(200, b"hello")
        elif p == "/redir": self.send(302, b"", [("Location", "/hello")])
        elif p == "/login": self.send(200, b"in", [("Set-Cookie", "sid=abc; Path=/; HttpOnly"), ("Set-Cookie", "t=1; Max-Age=60")])
        elif p == "/whoami": self.send(200, ("cookie=" + (self.headers.get("Cookie") or "-")).encode())
        elif p == "/gz":
            body = gzip.compress(b"z" * 5000)
            self.send(200, body, [("Content-Encoding", "gzip")])
        else: self.send(404, b"no")
    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n)
        if self.path == "/redir307": self.send(307, b"", [("Location", "/echo")])
        elif self.path == "/redir302": self.send(302, b"", [("Location", "/echo")])
        elif self.path == "/echo": self.send(200, b"POST " + body)
        else: self.send(404, b"no")
s = ThreadingHTTPServer(("127.0.0.1", 0), H)
print(s.server_address[1], flush=True)
s.serve_forever()
PY
python3 -I "$T/srv.py" > "$T/port" 2>/dev/null &
i=0; while [ ! -s "$T/port" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i+1)); done
port=$(cat "$T/port")
"$bin/pool_interop" client "$port" > "$T/client.out" 2>&1
got=$(cat "$T/client.out")
case "$got" in
  *"200 hello"*"200 in"*"cookie=sid=abc; t=1"*"200 POST body"*) echo "ok   pool interop: redirects, cookies, 307 against python http.server" ;;
  *) echo "FAIL pool interop: client"; cat "$T/client.out" | head -20; fail=1 ;;
esac
if grep -q "opened=1" "$T/client.out"; then echo "ok   pool interop: one keep-alive connection for the whole run"; else echo "FAIL pool interop: connections"; fail=1; fi
exit $fail
