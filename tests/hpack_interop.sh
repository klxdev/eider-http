#!/bin/sh
# http/hpack against libnghttp2, both ways, on random header blocks (tests/hpack_oracle.c):
#   nghttp2's encoding, decoded by http/hpack, gives the fields that were encoded;
#   http/hpack's encoding, decoded by nghttp2, gives the same fields.
# usage: sh tests/hpack_interop.sh <dir with the built hpack_interop program>   (`skip` without libnghttp2)
here=$(cd "$(dirname "$0")/.." && pwd -P)
B=$1
if ! [ -f /usr/include/nghttp2/nghttp2.h ] || ! ${CC:-cc} -O1 -o "$B/hpack_oracle" "$here/tests/hpack_oracle.c" -lnghttp2 2>"$B/cc.log"; then
  echo "skip hpack interop: libnghttp2 and its header are not installed"
  exit 0
fi
fail=0
for seed in 1 2 3 4 5; do
  "$B/hpack_oracle" gen "$seed" 400 > "$B/fields.txt"
  "$B/hpack_oracle" deflate < "$B/fields.txt" > "$B/theirs.hex"
  { echo decode; cat "$B/theirs.hex"; } | "$B/hpack_interop" > "$B/decoded.txt"
  if ! cmp -s "$B/fields.txt" "$B/decoded.txt"; then echo "FAIL hpack interop: nghttp2 -> http/hpack (seed $seed)"; fail=1; fi
  { echo encode; cat "$B/fields.txt"; } | "$B/hpack_interop" > "$B/ours.hex"
  "$B/hpack_oracle" inflate < "$B/ours.hex" > "$B/inflated.txt"
  if ! cmp -s "$B/fields.txt" "$B/inflated.txt"; then echo "FAIL hpack interop: http/hpack -> nghttp2 (seed $seed)"; fail=1; fi
done
[ "$fail" = 0 ] && echo "ok   hpack interop (nghttp2, both directions, 5 x 400 blocks)"
exit $fail
