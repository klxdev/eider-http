#!/bin/sh
# Interoperability of http/h2 with other HTTP/2 implementations, over loopback:
#
#   sh tests/h2_interop.sh <dir with the built h2srv and h2cli>
#
#   curl (nghttp2)         against the Eider server: prior-knowledge h2c (GET, POST, a 1 MiB body, a streamed body), and
#                          over https with ALPN h2; HTTP/1.1 on the same port still works
#   the Rust `h2` crate    (hyper's HTTP/2) as a client of the Eider server (tests/h2_rust_client, `cargo`), and as a
#                          server for the Eider client (tests/h2_interop_client.ei): unary with trailers, a
#                          bidirectional stream, 4 MiB through the windows, 1 MiB back, 50 concurrent calls
#   h2spec                 (https://github.com/summerwind/h2spec; $H2SPEC or on the PATH) strict, against an
#                          HTTP/2-only Eider server (`h2srv h2only`: the one test about an invalid preface expects
#                          GOAWAY, which a server that shares its port with HTTP/1.1 answers in HTTP/1.1)
#
# Prints `ok   h2 interop: <case>` or `FAIL h2 interop: <case>`; `skip` for a tool that is not installed; exits 1 on a failure.
here=$(cd "$(dirname "$0")/.." && pwd -P)
bin=$1
P=$here/tests/pki
[ -x "$bin/h2srv" ] && [ -x "$bin/h2cli" ] || { echo "FAIL h2 interop: $bin has no h2srv and h2cli"; exit 1; }
T=$(mktemp -d)
trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$T"' EXIT
fail=0

check() { # name, output file, pattern...
  name=$1; out=$2; shift 2
  for pat in "$@"; do
    if ! grep -q -- "$pat" "$out"; then
      echo "FAIL h2 interop: $name (missing: $pat)"; sed 's/^/    | /' "$out" | head -20; fail=1; return
    fi
  done
  echo "ok   h2 interop: $name"
}

wait_for() { # file, pattern
  i=0
  while [ $i -lt 100 ]; do
    grep -q -- "$2" "$1" 2>/dev/null && return 0
    sleep 0.1; i=$((i + 1))
  done
  return 1
}

# ---- the Eider server, plain and https ----
"$bin/h2srv" "$P/ec.pem" "$P/ec.key" > "$T/srv.log" 2>&1 &
wait_for "$T/srv.log" listening || { echo "FAIL h2 interop: the Eider server did not start"; cat "$T/srv.log"; exit 1; }
port=$(sed -n 's/^listening \([0-9]*\) .*/\1/p' "$T/srv.log" | head -1)
tport=$(sed -n 's/^listening [0-9]* \([0-9]*\)/\1/p' "$T/srv.log" | head -1)

if command -v curl >/dev/null 2>&1 && curl -V | grep -q nghttp2; then
  curl -sS --max-time 20 --http2-prior-knowledge -w '\nversion=%{http_version}\n' "http://127.0.0.1:$port/hello" > "$T/o" 2>&1
  check "curl h2c prior knowledge: GET" "$T/o" "hello h2" "version=2"
  curl -sS --max-time 20 --http2-prior-knowledge -d 'hello from curl' "http://127.0.0.1:$port/echo" > "$T/o" 2>&1
  check "curl h2c prior knowledge: POST" "$T/o" "HELLO FROM CURL"
  curl -sS --max-time 20 --http2-prior-knowledge "http://127.0.0.1:$port/info" > "$T/o" 2>&1
  check "curl h2c: the handler sees protocol=h2 and the authority" "$T/o" "protocol=h2" "host=127.0.0.1:$port"
  sum=$(curl -sS --max-time 20 --http2-prior-knowledge "http://127.0.0.1:$port/big" | md5sum | cut -d' ' -f1)
  echo "$sum" > "$T/o"
  check "curl h2c: a 1 MiB body" "$T/o" "8f293a2f6c19b345152f7a49bb4c643c"
  n=$(curl -sS --max-time 20 --http2-prior-knowledge "http://127.0.0.1:$port/stream" | wc -c)
  echo "streamed $n" > "$T/o"
  check "curl h2c: a streamed body (10 chunks)" "$T/o" "streamed 330"
  curl -sS --max-time 20 --http2-prior-knowledge -Z "http://127.0.0.1:$port/hello" "http://127.0.0.1:$port/hello" "http://127.0.0.1:$port/info" > "$T/o" 2>&1
  check "curl h2c: three requests at once" "$T/o" "hello h2hello h2" "protocol=h2"
  curl -sS --max-time 20 "http://127.0.0.1:$port/hello" > "$T/o" 2>&1
  check "curl: HTTP/1.1 on the same port" "$T/o" "hello h2"
  curl -sS --max-time 20 --http2 --cacert "$P/root.pem" -w '\nversion=%{http_version}\n' "https://localhost:$tport/info" > "$T/o" 2>&1
  check "curl https: ALPN h2" "$T/o" "protocol=h2" "tls=TLS_" "version=2"
  curl -sS --max-time 20 --http2 --cacert "$P/root.pem" -d 'tls body' "https://localhost:$tport/echo" > "$T/o" 2>&1
  check "curl https: POST over h2" "$T/o" "TLS BODY"
  curl -sS --max-time 20 --http1.1 --cacert "$P/root.pem" "https://localhost:$tport/hello" > "$T/o" 2>&1
  check "curl https: HTTP/1.1 (ALPN http/1.1) on the same port" "$T/o" "hello h2"
else
  echo "skip h2 interop: curl with nghttp2 is not installed"
fi

# ---- the Rust h2 crate ----
if command -v cargo >/dev/null 2>&1; then
  if (cd "$here/tests/h2_rust_client" && cargo build --release > "$T/cargo.log" 2>&1); then
    R=$here/tests/h2_rust_client/target/release
    timeout 120 "$R/h2_rust_client" "$port" > "$T/o" 2>&1; echo "exit $?" >> "$T/o"
    check "Rust h2 client against the Eider server" "$T/o" "ok   unary POST /echo" "ok   bidirectional /bidi" "ok   trailers /trailers" "ok   4 MiB upload is refused with 413" "ok   1 MiB download /big" "ok   50 concurrent calls" "exit 0"
    "$R/h2_rust_server" > "$T/rs.log" 2>&1 &
    wait_for "$T/rs.log" listening
    rport=$(sed -n 's/^listening //p' "$T/rs.log" | head -1)
    timeout 120 "$bin/h2cli" "$rport" > "$T/o" 2>&1; echo "exit $?" >> "$T/o"
    check "Eider client against the Rust h2 server" "$T/o" "ok   unary POST /echo" "ok   trailer x-len" "ok   bidirectional /bidi" "ok   4 MiB upload /sum" "ok   1 MiB download /big" "ok   Client.fetch" "ok   50 concurrent calls" "exit 0"
  else
    echo "FAIL h2 interop: cargo build of tests/h2_rust_client"; tail -20 "$T/cargo.log"; fail=1
  fi
else
  echo "skip h2 interop: cargo is not installed (the Rust h2 crate)"
fi

# ---- h2spec ----
H2SPEC=${H2SPEC:-$(command -v h2spec 2>/dev/null)}
if [ -n "$H2SPEC" ] && [ -x "$H2SPEC" ]; then
  "$bin/h2srv" h2only > "$T/srv2.log" 2>&1 &
  wait_for "$T/srv2.log" listening
  p2=$(sed -n 's/^listening //p' "$T/srv2.log" | head -1)
  "$H2SPEC" -h 127.0.0.1 -p "$p2" -S -o 5 > "$T/o" 2>&1
  check "h2spec (strict, HTTP/2-only server): every test passes" "$T/o" " 0 failed"
  tail -1 "$T/o" | sed 's/^/     /'
else
  echo "skip h2 interop: h2spec is not installed (set H2SPEC=/path/to/h2spec; https://github.com/summerwind/h2spec)"
fi
exit $fail
