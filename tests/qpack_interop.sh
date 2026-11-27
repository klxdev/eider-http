#!/bin/sh
# http/qpack against libnghttp3, both ways, on random header sections (tests/qpack_oracle.c):
#   nghttp3's encoding (encoder stream and sections), decoded by http/qpack, gives the fields that were encoded;
#   http/qpack's encoding, decoded by nghttp3, gives the same fields; and nghttp3 decodes the 99 static table
#   entries to what http/qpack has (the table is printed by tests/qpack_test.ei).
# usage: sh tests/qpack_interop.sh <dir with the built qpack_interop program>
# `skip` without libnghttp3 (only its shared library is needed: the oracle declares the prototypes it uses).
here=$(cd "$(dirname "$0")/.." && pwd -P)
B=$1
lib=
for f in /usr/lib64/libnghttp3.so.9 /usr/lib/libnghttp3.so.9 /usr/lib/x86_64-linux-gnu/libnghttp3.so.9 /usr/lib/aarch64-linux-gnu/libnghttp3.so.9 /usr/lib64/libnghttp3.so /usr/lib/libnghttp3.so; do
  [ -f "$f" ] && lib=$f && break
done
if [ -z "$lib" ] || ! ${CC:-cc} -O1 -o "$B/qpack_oracle" "$here/tests/qpack_oracle.c" "$lib" 2>"$B/cc.log"; then
  echo "skip qpack interop: libnghttp3 is not installed"
  exit 0
fi
fail=0
"$B/qpack_oracle" static > "$B/static.txt"
sed -n '/^-- static table/,/^-- RFC/p' "$here/tests/qpack_test.out" | sed '1,2d;$d' > "$B/ours_static.txt"
if ! cmp -s "$B/static.txt" "$B/ours_static.txt"; then echo "FAIL qpack interop: static table"; fail=1; fi
for cfg in "4096 16" "300 2" "0 0" "1024 1"; do
  set -- $cfg
  cap=$1; blk=$2
  for seed in 1 2 3 4 5; do
    "$B/qpack_oracle" gen "$seed" 300 > "$B/fields.txt"
    { echo "encode $cap $blk"; cat "$B/fields.txt"; } > "$B/enc_in.txt"
    "$B/qpack_oracle" encode "$cap" "$blk" < "$B/fields.txt" > "$B/theirs.txt"
    { echo "decode $cap $blk"; cat "$B/theirs.txt"; } | "$B/qpack_interop" > "$B/decoded.txt"
    if ! cmp -s "$B/fields.txt" "$B/decoded.txt"; then echo "FAIL qpack interop: nghttp3 -> http/qpack (table $cap, blocked $blk, seed $seed)"; fail=1; fi
    "$B/qpack_interop" < "$B/enc_in.txt" > "$B/ours.txt"
    "$B/qpack_oracle" decode "$cap" "$blk" < "$B/ours.txt" > "$B/inflated.txt"
    if ! cmp -s "$B/fields.txt" "$B/inflated.txt"; then echo "FAIL qpack interop: http/qpack -> nghttp3 (table $cap, blocked $blk, seed $seed)"; fail=1; fi
  done
done
[ "$fail" = 0 ] && echo "ok   qpack interop (nghttp3, both directions, 4 table sizes x 5 seeds x 300 sections)"
exit $fail
