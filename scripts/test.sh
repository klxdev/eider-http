#!/bin/sh
# eider-http's tests.
#
#   sh scripts/test.sh             scripts/build.sh, then every test
#   NOBUILD=1 sh scripts/test.sh   skip scripts/build.sh (the locks are already fetched)
#
# Every tests/*.ei and examples/*/tests/*.ei is run with the toolchain's compiler (`eider run`) and its
# output compared with the .out next to it. The tests in TSAN (they use threads) are then
# built once under ThreadSanitizer and run once each, when $CC can build a TSan program
# (else `skip`). tests/tls_interop.sh then runs the https server against `openssl s_client` and `curl` and the
# client against `openssl s_server` (`skip` without openssl). Prints `ok   <test>` or `FAIL <test>` with a diff, then `ALL OK`; exits 1
# on a failure, 2 when there is no usable toolchain (scripts/env.sh).
TSAN="tests/h2_test.ei tests/h2_rst_noerror_test.ei tests/h2_upgrade_test.ei tests/client_host_test.ei tests/service_test.ei tests/observe_test.ei tests/ratelimit_test.ei tests/trap_test.ei tests/server_test.ei tests/middleware_test.ei tests/stream_test.ei tests/ws_test.ei tests/compress_test.ei tests/tls_test.ei"
here=$(cd "$(dirname "$0")/.." && pwd -P)
if [ -z "$NOBUILD" ]; then
  sh "$here/scripts/build.sh" || exit $?
fi
. "$here/scripts/env.sh"
cd "$here" || exit 1
fail=0
for f in tests/*.ei examples/*/tests/*.ei; do
  [ -f "$f" ] && [ -f "${f%.ei}.out" ] || continue
  got=$(ei run "$f" 2>&1 < /dev/null)
  if [ "$got" = "$(cat "${f%.ei}.out")" ]; then echo "ok   $f"; else echo "FAIL $f"; echo "$got" | diff "${f%.ei}.out" - | head -10; fail=1; fi
done
# tests/profiled/*.ei are run with --profile=cpu,mem (the profiler's endpoints need it)
for f in tests/profiled/*.ei; do
  [ -f "$f" ] && [ -f "${f%.ei}.out" ] || continue
  got=$(ei run --profile=cpu,mem "$f" 2>&1 < /dev/null)
  if [ "$got" = "$(cat "${f%.ei}.out")" ]; then echo "ok   $f (--profile)"; else echo "FAIL $f (--profile)"; echo "$got" | diff "${f%.ei}.out" - | head -10; fail=1; fi
done
# https against other implementations, both directions (tests/tls_interop.sh)
if command -v openssl >/dev/null 2>&1; then
  B=$(mktemp -d)
  if ei build tests/tls_interop_server.ei -o "$B/iserver" > "$B/log" 2>&1 && ei build tests/tls_interop_client.ei -o "$B/iclient" >> "$B/log" 2>&1; then
    sh tests/tls_interop.sh "$B" || fail=1
  else
    echo "FAIL tls interop: build"; cat "$B/log"; fail=1
  fi
  rm -rf "$B"
else
  echo "skip tls interop: no openssl on the PATH"
fi
# http/hpack against libnghttp2, both directions (tests/hpack_interop.sh; `skip` without libnghttp2)
B=$(mktemp -d)
if ei build tests/hpack_interop.ei -o "$B/hpack_interop" > "$B/log" 2>&1; then
  sh tests/hpack_interop.sh "$B" || fail=1
else
  echo "FAIL hpack interop: build"; cat "$B/log"; fail=1
fi
rm -rf "$B"
# http/h2 against curl, the Rust h2 crate and h2spec (tests/h2_interop.sh; `skip` for what is not installed)
B=$(mktemp -d)
if ei build tests/h2_interop_server.ei -o "$B/h2srv" > "$B/log" 2>&1 && ei build tests/h2_interop_client.ei -o "$B/h2cli" >> "$B/log" 2>&1; then
  sh tests/h2_interop.sh "$B" || fail=1
else
  echo "FAIL h2 interop: build"; cat "$B/log"; fail=1
fi
rm -rf "$B"
# http/multipart against curl -F and Python's email/http stdlib (tests/multipart_interop.sh; `skip` for what is not installed)
B=$(mktemp -d)
if ei build tests/multipart_interop_server.ei -o "$B/mpsrv" > "$B/log" 2>&1; then
  sh tests/multipart_interop.sh "$B" || fail=1
else
  echo "FAIL multipart interop: build"; cat "$B/log"; fail=1
fi
rm -rf "$B"
# http/jwt against python3's hmac and hashlib (tests/jwt_interop.sh; `skip` without python3)
B=$(mktemp -d)
if ei build tests/jwt_interop_prog.ei -o "$B/jwt_interop_prog" > "$B/log" 2>&1; then
  sh tests/jwt_interop.sh "$B" || fail=1
else
  echo "FAIL jwt interop: build"; cat "$B/log"; fail=1
fi
rm -rf "$B"
# http/unixsock and http/proxyproto against curl and python3 (tests/unixsock_interop.sh; `skip` for what is not installed)
B=$(mktemp -d)
if ei build tests/unixsock_interop_server.ei -o "$B/usrv" > "$B/log" 2>&1; then
  sh tests/unixsock_interop.sh "$B" || fail=1
else
  echo "FAIL unixsock interop: build"; cat "$B/log"; fail=1
fi
rm -rf "$B"
if [ -n "$TSAN" ]; then
  T=$(mktemp -d)
  trap 'rm -rf "$T"' EXIT
  # (the probe uses longjmp, which traps rely on: a TSan that cannot follow it, as on glibc 2.4x, is skipped)
  printf '#include <setjmp.h>\nstatic jmp_buf j;\nstatic void jump(void) { longjmp(j, 1); }\nint main(void) { if (setjmp(j) == 0) jump(); return 0; }\n' > "$T/probe.c"
  if ${CC:-cc} -fsanitize=thread -o "$T/probe" "$T/probe.c" 2>/dev/null && "$T/probe" >/dev/null 2>&1; then
    for f in $TSAN; do
      if ! (EIDER_CACHE=off EIDER_CFLAGS="-fsanitize=thread -g"; export EIDER_CACHE EIDER_CFLAGS; ei build "$f" -o "$T/t") > "$T/log" 2>&1; then
        echo "FAIL $f (tsan): build"; cat "$T/log"; fail=1; continue
      fi
      got=$(TSAN_OPTIONS="halt_on_error=1 exitcode=66" "$T/t" < /dev/null 2>&1)
      if [ "$got" = "$(cat "${f%.ei}.out")" ]; then echo "ok   $f (tsan)"; else echo "FAIL $f (tsan)"; echo "$got" | diff "${f%.ei}.out" - | head -20; fail=1; fi
    done
  else
    echo "skip tsan runs ($TSAN): ${CC:-cc} cannot build a -fsanitize=thread program"
  fi
fi
[ $fail = 0 ] && echo "ALL OK"
exit $fail
