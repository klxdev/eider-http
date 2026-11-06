#!/bin/sh
# Interoperability of eider-http's https with other implementations, over loopback:
#
#   sh tests/tls_interop.sh <dir with the built iserver and iclient>
#
# - the Eider server (tests/tls_interop_server.ei) against `openssl s_client` and `curl`, and
# - the Eider client (tests/tls_interop_client.ei) against `openssl s_server -www`,
#
# with the certificates in tests/pki. Prints `ok   tls interop: <case>` or `FAIL tls interop: <case>`;
# exits 1 on a failure and 0 when everything passed (`skip` for a tool that is not installed).
here=$(cd "$(dirname "$0")/.." && pwd -P)
bin=$1
P=$here/tests/pki
if ! command -v openssl >/dev/null 2>&1; then
  echo "skip tls interop: no openssl on the PATH"
  exit 0
fi
[ -x "$bin/iserver" ] && [ -x "$bin/iclient" ] || { echo "FAIL tls interop: $bin has no iserver and iclient"; exit 1; }
T=$(mktemp -d)
trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$T"' EXIT
fail=0
n=0
port=$(( 20000 + $$ % 20000 ))

check() { # name, output file, pattern...
  name=$1; out=$2; shift 2
  for pat in "$@"; do
    if ! grep -q -- "$pat" "$out"; then
      echo "FAIL tls interop: $name (missing: $pat)"; sed 's/^/    | /' "$out" | head -20; fail=1; return
    fi
  done
  echo "ok   tls interop: $name"
}

wait_for() { # file, pattern
  i=0
  while [ $i -lt 100 ]; do
    grep -q -- "$2" "$1" 2>/dev/null && return 0
    sleep 0.1; i=$((i + 1))
  done
  return 1
}

# ---- the Eider server: serve <chain> <key> [server options]; sets $sport; stop_server ends it
serve() {
  n=$((n + 1))
  "$bin/iserver" "$@" > "$T/srv$n.log" 2>&1 &
  spid=$!
  wait_for "$T/srv$n.log" listening || { echo "FAIL tls interop: the Eider server did not start"; cat "$T/srv$n.log"; fail=1; return 1; }
  sport=$(sed -n 's/^listening //p' "$T/srv$n.log" | head -1)
}
stop_server() {
  kill $spid 2>/dev/null; wait $spid 2>/dev/null
}

req() { printf 'GET %s HTTP/1.1\r\nHost: localhost\r\n%sConnection: close\r\n\r\n' "$1" "$2"; }

SC="-CAfile $P/root.pem -verify_return_error -servername localhost -alpn http/1.1 -quiet"
SC_V="-CAfile $P/root.pem -verify_return_error -servername localhost -alpn http/1.1 -ign_eof"

# ======== the Eider server against openssl s_client
serve $P/edchain.pem $P/ed.key || exit 1
req /hello > "$T/q"
openssl s_client -connect 127.0.0.1:$sport $SC_V < "$T/q" > "$T/o" 2>&1
check "s_client: GET over TLS 1.3, ALPN http/1.1, chain verified" "$T/o" "Protocol *: TLSv1.3" "ALPN protocol: http/1.1" "Verify return code: 0" "HTTP/1.1 200" "hello tls"
openssl s_client -connect 127.0.0.1:$sport $SC < "$T/q" > "$T/o" 2>&1
check "s_client -quiet: clean end" "$T/o" "hello tls"
# a request in two writes, a second apart: partial request head across two records
( printf 'GET /hello HTTP/1.1\r\nHost: localhost\r\n'; sleep 1; printf 'Connection: close\r\n\r\n' ) | openssl s_client -connect 127.0.0.1:$sport $SC > "$T/o" 2>&1
check "s_client: one request in two TLS records" "$T/o" "HTTP/1.1 200" "hello tls"
# two requests on one connection (keep-alive), then close
( printf 'GET /hello HTTP/1.1\r\nHost: localhost\r\n\r\n'; sleep 0.5; printf 'GET /info HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n' ) | openssl s_client -connect 127.0.0.1:$sport $SC > "$T/o" 2>&1
check "s_client: keep-alive, two requests" "$T/o" "hello tls" "tls=TLS_" "peer=127.0.0.1:"
req /stream > "$T/q"
openssl s_client -connect 127.0.0.1:$sport $SC < "$T/q" > "$T/o" 2>&1
check "s_client: a chunked streaming response" "$T/o" "Transfer-Encoding: chunked" "0123456789abcdef0123456789abcdef"
test "$(grep -c '^0123456789abcdef' "$T/o")" = 20 && echo "ok   tls interop: s_client: all 20 chunks" || { echo "FAIL tls interop: s_client: all 20 chunks"; fail=1; }
# the TLS versions and protocols the server refuses
req /hello > "$T/q"
openssl s_client -connect 127.0.0.1:$sport -tls1_2 -CAfile $P/root.pem < "$T/q" > "$T/o" 2>&1
check "s_client: TLS 1.2 only is refused" "$T/o" "alert protocol version\|no protocols available\|wrong version\|handshake failure"
openssl s_client -connect 127.0.0.1:$sport -alpn h2 -CAfile $P/root.pem < "$T/q" > "$T/o" 2>&1
check "s_client: ALPN h2 only is refused" "$T/o" "no application protocol\|alert"
if ! grep -q "HTTP/1.1 200" "$T/o"; then echo "ok   tls interop: s_client: nothing served for ALPN h2"; else echo "FAIL tls interop: s_client: served a request for ALPN h2"; fail=1; fi
openssl s_client -connect 127.0.0.1:$sport -servername localhost -CAfile $P/other-root.pem -verify_return_error < "$T/q" > "$T/o" 2>&1
check "s_client: the client's own verification (server chain vs another root)" "$T/o" "unable to get local issuer\|Verify return code: [1-9]"
# curl
if command -v curl >/dev/null 2>&1; then
  curl -sS --max-time 20 --http1.1 --cacert $P/root.pem https://127.0.0.1:$sport/hello > "$T/o" 2>&1; echo "exit $?" >> "$T/o"
  check "curl --cacert: GET" "$T/o" "hello tls" "exit 0"
  curl -sS --max-time 20 --http1.1 --cacert $P/root.pem https://localhost:$sport/hello https://localhost:$sport/info > "$T/o" 2>&1; echo "exit $?" >> "$T/o"
  check "curl --cacert: two requests (one connection reused), by name" "$T/o" "hello tls" "tls=TLS_" "exit 0"
  curl -sS --max-time 20 --http1.1 --cacert $P/other-root.pem https://127.0.0.1:$sport/hello > "$T/o" 2>&1; echo "exit $?" >> "$T/o"
  check "curl: untrusted root is refused" "$T/o" "exit 60"
  curl -sS --max-time 20 --http1.1 --tlsv1.3 --cacert $P/root.pem https://127.0.0.1:$sport/stream > "$T/o" 2>&1; echo "exit $?" >> "$T/o"
  check "curl --tlsv1.3: streaming" "$T/o" "0123456789abcdef" "exit 0"
  curl -sS --max-time 20 --http1.1 --tls-max 1.2 --cacert $P/root.pem https://127.0.0.1:$sport/hello > "$T/o" 2>&1; echo "exit $?" >> "$T/o"
  check "curl --tls-max 1.2: refused" "$T/o" "exit [1-9]"
else
  echo "skip tls interop: no curl on the PATH"
fi
curl -sS --max-time 20 --cacert $P/root.pem https://127.0.0.1:$sport/quit > /dev/null 2>&1 || openssl s_client -connect 127.0.0.1:$sport -CAfile $P/root.pem -quiet < /dev/null > /dev/null 2>&1
stop_server

# RSA and P-384 server certificates (and the roots of their chains)
serve $P/rsa2048chain.pem $P/rsa2048.key || exit 1
req /hello > "$T/q"
openssl s_client -connect 127.0.0.1:$sport -CAfile $P/rsa-root.pem -verify_return_error -servername localhost -alpn http/1.1 -quiet < "$T/q" > "$T/o" 2>&1
check "s_client: RSA-2048 certificate through an RSA intermediate" "$T/o" "HTTP/1.1 200" "hello tls"
stop_server
serve $P/p384.pem $P/p384.key || exit 1
openssl s_client -connect 127.0.0.1:$sport -CAfile $P/p384-root.pem -verify_return_error -servername localhost -alpn http/1.1 -quiet < "$T/q" > "$T/o" 2>&1
check "s_client: P-384 certificate" "$T/o" "HTTP/1.1 200" "hello tls"
stop_server

# client certificates
serve $P/edchain.pem $P/ed.key clientca=$P/root.pem require=1 || exit 1
req /info > "$T/q"
openssl s_client -connect 127.0.0.1:$sport $SC -cert $P/client.pem -key $P/client.key < "$T/q" > "$T/o" 2>&1
check "s_client: a required client certificate, sent" "$T/o" "HTTP/1.1 200" "cert=[1-9]"
openssl s_client -connect 127.0.0.1:$sport $SC < "$T/q" > "$T/o" 2>&1
if grep -q "HTTP/1.1 200" "$T/o"; then echo "FAIL tls interop: s_client: no client certificate was served"; fail=1; else echo "ok   tls interop: s_client: no client certificate is refused"; fi
if command -v curl >/dev/null 2>&1; then
  curl -sS --max-time 20 --http1.1 --cacert $P/root.pem --cert $P/client.pem --key $P/client.key https://127.0.0.1:$sport/info > "$T/o" 2>&1; echo "exit $?" >> "$T/o"
  check "curl --cert: client certificate" "$T/o" "cert=[1-9]" "exit 0"
  curl -sS --max-time 20 --http1.1 --cacert $P/root.pem https://127.0.0.1:$sport/info > "$T/o" 2>&1; echo "exit $?" >> "$T/o"
  check "curl without a certificate: refused" "$T/o" "exit [1-9]"
fi
stop_server

# ======== the Eider client against openssl s_server -www
client() { # name, s_server args -- client args ; $cur is the client's output
  name=$1; shift
  n=$((n + 1)); port=$((port + 1))
  sargs=""
  while [ "$1" != "--" ]; do sargs="$sargs $1"; shift; done
  shift
  # shellcheck disable=SC2086
  openssl s_server -accept $port -www -naccept 1 $sargs > "$T/s$n.log" 2>&1 &
  cpid=$!
  wait_for "$T/s$n.log" ACCEPT || { echo "FAIL tls interop: $name (s_server did not start)"; cat "$T/s$n.log"; fail=1; return 1; }
  "$bin/iclient" $port "${CA:-$P/root.pem}" "$@" > "$T/c$n.out" 2>&1
  echo "exit $?" >> "$T/c$n.out"
  kill $cpid 2>/dev/null; wait $cpid 2>/dev/null
  cur=$T/c$n.out
}

client "client / s_server: Ed25519 leaf via intermediate, ALPN http/1.1" -cert $P/ed.pem -cert_chain $P/inter.pem -key $P/ed.key -alpn http/1.1 -- localhost && check "$name" "$cur" "status 200" "alpn http/1.1" "s_server" "exit 0"
client "client / s_server: by IP address (SAN iPAddress)" -cert $P/ed.pem -cert_chain $P/inter.pem -key $P/ed.key -- 127.0.0.1 && check "$name" "$cur" "status 200" "exit 0"
client "client / s_server: ECDSA P-256 leaf" -cert $P/ec.pem -key $P/ec.key -- localhost && check "$name" "$cur" "status 200" "exit 0"
CA=$P/rsa-root.pem
client "client / s_server: RSA-2048 leaf through an RSA intermediate" -cert $P/rsa2048.pem -cert_chain $P/rsa-inter.pem -key $P/rsa2048.key -- localhost && check "$name" "$cur" "status 200" "exit 0"
CA=$P/p384-root.pem
client "client / s_server: P-384 leaf" -cert $P/p384.pem -key $P/p384.key -- localhost && check "$name" "$cur" "status 200" "exit 0"
CA=
client "client / s_server: a file path" -cert $P/ed.pem -cert_chain $P/inter.pem -key $P/ed.key -- localhost /hello && check "$name" "$cur" "status 200" "exit 0"
client "client / s_server: wrong host name is refused" -cert $P/ed.pem -cert_chain $P/inter.pem -key $P/ed.key -- 127.0.0.2 && check "$name" "$cur" "certificate is not valid for the host name" "exit 2"
CA=$P/other-root.pem
client "client / s_server: untrusted root" -cert $P/ec.pem -key $P/ec.key -- localhost && check "$name" "$cur" "unable to find a trusted issuer" "exit 2"
CA=
client "client / s_server: expired certificate is refused" -cert $P/expired.pem -key $P/expired.key -- localhost && check "$name" "$cur" "certificate has expired" "exit 2"
client "client / s_server: a certificate for clients only is refused" -cert $P/noeku.pem -key $P/noeku.key -- localhost && check "$name" "$cur" "error" "exit 2"
client "client / s_server: verification off (tests only) accepts the wrong name" -cert $P/ed.pem -cert_chain $P/inter.pem -key $P/ed.key -- 127.0.0.2 / insecure=1 && check "$name" "$cur" "status 200" "exit 0"
client "client / s_server: TLS 1.2 only is refused" -tls1_2 -cert $P/ed.pem -cert_chain $P/inter.pem -key $P/ed.key -- localhost && check "$name" "$cur" "error" "exit 2"
client "client / s_server: a client certificate when asked" -Verify 1 -CAfile $P/root.pem -cert $P/ed.pem -cert_chain $P/inter.pem -key $P/ed.key -- localhost / identity=$P/client.pem,$P/client.key && check "$name" "$cur" "status 200" "exit 0"
client "client / s_server: no client certificate where one is required" -Verify 1 -CAfile $P/root.pem -cert $P/ed.pem -cert_chain $P/inter.pem -key $P/ed.key -- localhost && check "$name" "$cur" "error" "exit 2"

[ $fail = 0 ] && echo "ok   tls interop: all"
exit $fail
