#!/bin/sh
# http/multipart against other implementations, over loopback:
#
#   sh tests/multipart_interop.sh <dir with the built mpsrv>
#
#   curl -F      uploads (fields, files with types and names, a file read from stdin, a 300 KB binary file,
#                a request that is not multipart, a body cut short) against the Eider server
#   python3      (stdlib only) builds bodies with email.mime that the Eider parser reads (tests/multipart_interop.py) and
#                parses a body the Eider builder wrote with email.parser
#
# Prints `ok   multipart interop: <case>` or `FAIL multipart interop: <case>`; `skip` for a tool that is not installed;
# exits 1 on a failure.
here=$(cd "$(dirname "$0")/.." && pwd -P)
bin=$1
[ -x "$bin/mpsrv" ] || { echo "FAIL multipart interop: $bin has no mpsrv"; exit 1; }
T=$(mktemp -d)
trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$T"' EXIT
fail=0

"$bin/mpsrv" > "$T/srv.log" 2>&1 &
i=0
while [ $i -lt 100 ] && ! grep -q listening "$T/srv.log" 2>/dev/null; do sleep 0.1; i=$((i + 1)); done
port=$(sed -n 's/^listening \([0-9]*\).*/\1/p' "$T/srv.log" | head -1)
[ -n "$port" ] || { echo "FAIL multipart interop: the Eider server did not start"; cat "$T/srv.log"; exit 1; }

sum_of() { od -An -v -tu1 "$1" | awk '{for(i=1;i<=NF;i++)s+=$i} END{print s%1000003}'; }

check() { # name, output file, expected file
  if cmp -s "$2" "$3"; then echo "ok   multipart interop: $1"; else
    echo "FAIL multipart interop: $1"; echo "  want:"; sed 's/^/    | /' "$3" | head -20; echo "  got:"; sed 's/^/    | /' "$2" | head -20; fail=1
  fi
}

if command -v curl >/dev/null 2>&1; then
  printf 'line1\r\n--x\r\nline2' > "$T/t.txt"
  head -c 300000 /dev/urandom > "$T/big.bin"
  big=$(sum_of "$T/big.bin"); ts=$(sum_of "$T/t.txt")
  curl -sS --max-time 30 -F 'a=hello' -F "f=@$T/t.txt;type=text/x-t" -F "g=@$T/big.bin;filename=data.bin" -F "h=<$T/t.txt" "http://127.0.0.1:$port/upload" > "$T/o" 2>&1
  printf 'a|-|text/plain|5|532\nf|t.txt|text/x-t|17|%s\ng|data.bin|application/octet-stream|300000|%s\nh|-|text/plain|17|%s\n' "$ts" "$big" "$ts" > "$T/w"
  check "curl -F: fields, typed file, renamed 300 KB binary file, <file field" "$T/o" "$T/w"
  printf 'from stdin' | curl -sS --max-time 30 -F 'in=@-;filename=stdin.txt' -F 'k=v' "http://127.0.0.1:$port/upload" > "$T/o" 2>&1
  printf 'from stdin' > "$T/s"; ss=$(sum_of "$T/s")
  printf 'in|stdin.txt|text/plain|10|%s\nk|-|text/plain|1|118\n' "$ss" > "$T/w"
  check "curl -F: a file from stdin" "$T/o" "$T/w"
  curl -sS --max-time 30 -F "u=@$T/t.txt;filename=caf$(printf '\303\251').txt" "http://127.0.0.1:$port/upload" > "$T/o" 2>&1
  printf 'u|caf\303\251.txt|text/plain|17|%s\n' "$ts" > "$T/w"
  check "curl -F: a UTF-8 filename" "$T/o" "$T/w"
  curl -sS --max-time 30 -o /dev/null -w '%{http_code}\n' -d 'a=b' "http://127.0.0.1:$port/upload" > "$T/o" 2>&1
  echo 415 > "$T/w"
  check "curl -d (urlencoded) is 415" "$T/o" "$T/w"
  curl -sS --max-time 30 -o /dev/null -w '%{http_code}\n' -H 'Content-Type: multipart/form-data; boundary=zz' --data-binary "$(printf -- '--zz\r\nContent-Disposition: form-data; name=a\r\n\r\nx')" "http://127.0.0.1:$port/upload" > "$T/o" 2>&1
  echo 400 > "$T/w"
  check "a body cut before the closing boundary is 400" "$T/o" "$T/w"
  curl -sS --max-time 30 -o /dev/null -w '%{http_code}\n' -H 'Content-Type: multipart/form-data' --data-binary x "http://127.0.0.1:$port/upload" > "$T/o" 2>&1
  echo 400 > "$T/w"
  check "multipart/form-data without a boundary is 400" "$T/o" "$T/w"
else
  echo "skip multipart interop: curl is not installed"
fi

if command -v python3 >/dev/null 2>&1; then
  python3 -I "$here/tests/multipart_interop.py" "$port" > "$T/py" 2>&1 || fail=1
  cat "$T/py"
else
  echo "skip multipart interop: python3 is not installed"
fi

curl -sS --max-time 5 "http://127.0.0.1:$port/quit" > /dev/null 2>&1
exit $fail
