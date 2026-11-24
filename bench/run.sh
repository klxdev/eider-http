#!/bin/bash
# eider-http against axum: hello-world GET /users/:id over keep-alive loopback connections.
#
#   bash bench/run.sh [rounds] [secs]       (defaults: 3 rounds of 5 s, at 64 and 256 connections)
#
# The servers are pinned to CPUs 0-7 and the load generator to CPUs 8-15, so it wants a machine with
# 16 hardware threads and nothing else running (look at `uptime`; on another CPU count, edit the two
# `taskset` lists). Builds hello.ei, the axum server and the load generator into bench/out/ and
# bench/*/target. For each configuration it prints req/s (median of the rounds, as a share of axum's)
# and the server's CPU time per request (utime + stime from /proc, all its threads): the number to
# trust on a busy machine, which moves far less than req/s does.
here=$(cd "$(dirname "$0")" && pwd -P); out=$here/out; mkdir -p "$out"
rounds=${1:-3}; secs=${2:-5}
(cd "$here/axum" && cargo build --release -q) || exit 1
(cd "$here/loadgen" && cargo build --release -q) || exit 1
(cd "$here/.." && eider eiderc build bench/hello.ei -o "$out/hello") || exit 1
LG="taskset -c 8-15 $here/loadgen/target/release/loadgen"
cpu_of() { local t=0 p u s; for p in "$@"; do read u s < <(awk '{print $14, $15}' /proc/$p/stat); t=$((t+u+s)); done; echo $t; }
run() { # kind conns
  case $1 in
    axum)  taskset -c 0-7 "$here/axum/target/release/axum-bench" 8080 >/dev/null 2>&1 & ;;
    eider) taskset -c 0-7 "$out/hello" 8080 >/dev/null 2>&1 & ;;
  esac
  local pid=$!; sleep 1.2
  kill -0 $pid 2>/dev/null || { echo "$1: the server did not start (is port 8080 busy?)" >&2; return; }
  $LG 8080 /users/42 $2 8 1 >/dev/null
  local c0=$(cpu_of $pid); local r=$($LG 8080 /users/42 $2 8 $secs); local c1=$(cpu_of $pid)
  kill $pid; wait $pid 2>/dev/null; sleep 0.5
  local reqs=$(echo "$r" | sed -E 's/.*\(([0-9]+) reqs.*/\1/'); local rps=$(echo "$r" | awk '{print $1}')
  echo "$1 $2 $rps $(python3 -c "print(round(($c1-$c0)/100/$reqs*1e6,1))")"
}
res=$(for c in 64 256; do for i in $(seq $rounds); do for k in axum eider; do run $k $c; done; done; done)
echo "$res" | python3 -c '
import sys,statistics as st,collections
d=collections.defaultdict(list)
for l in sys.stdin:
    k,c,r,u=l.split(); d[(int(c),k)].append((float(r),float(u)))
for c in (64,256):
    base=st.median(x[0] for x in d[(c,"axum")])
    for k in ("axum","eider"):
        v=d.get((c,k))
        if v: r=st.median(x[0] for x in v); print(f"conns={c:<4} {k:<6} {r:>9.0f} req/s ({r/base*100:3.0f}% of axum)  cpu/req {st.median(x[1] for x in v):5.1f}us")
'
