#!/bin/sh
# http/jwt against python3's hmac and hashlib (an independent HMAC and base64url), both ways, for HS256/384/512:
#   a token MACed by python is verified by http/jwt (and refused once a character is flipped);
#   a token signed by http/jwt carries the MAC python computes over the same signing input.
# usage: sh tests/jwt_interop.sh <dir with the built jwt_interop_prog>   (`skip` without python3)
B=$1
if ! command -v python3 >/dev/null 2>&1; then
  echo "skip jwt interop: python3 is not installed"
  exit 0
fi
python3 -I - "$B/jwt_interop_prog" <<'PY'
import base64, hashlib, hmac, json, subprocess, sys
prog = sys.argv[1]
def b64(b): return base64.urlsafe_b64encode(b).rstrip(b'=').decode()
def unb64(s): return base64.urlsafe_b64decode(s + '=' * (-len(s) % 4))
def run(*a): return subprocess.run([prog, *a], capture_output=True, text=True, check=True).stdout.strip()
fails = 0
def check(ok, what):
    global fails
    if not ok:
        fails += 1
        print("FAIL jwt interop:", what)
secret = "interop secret é with some length to it, 32+"
for alg, h in (("HS256", hashlib.sha256), ("HS384", hashlib.sha384), ("HS512", hashlib.sha512)):
    for sub in ("ada", "Jürgen", "a\"b\\c", "x" * 200):
        payload = json.dumps({"sub": sub, "n": 12345}, separators=(',', ':'), ensure_ascii=False)
        head = json.dumps({"alg": alg, "typ": "JWT"}, separators=(',', ':'))
        si = b64(head.encode()) + '.' + b64(payload.encode())
        tok = si + '.' + b64(hmac.new(secret.encode(), si.encode(), h).digest())
        got = run("verify", alg, secret, tok)
        check(got == "ok " + sub, "python token, %s sub=%r: %r" % (alg, sub, got))
        bad = tok[:-4] + ('A' if tok[-4] != 'A' else 'B') + tok[-3:]
        check(run("verify", alg, secret, bad).startswith("refused"), "flipped signature accepted, %s" % alg)
        check(run("verify", alg, secret + "x", tok).startswith("refused"), "wrong secret accepted, %s" % alg)
        ours = run("sign", alg, secret, payload)
        hd, pl, sg = ours.split('.')
        check(unb64(pl).decode() == payload, "payload round trip, %s" % alg)
        check(json.loads(unb64(hd))["alg"] == alg, "header alg, %s" % alg)
        want = b64(hmac.new(secret.encode(), (hd + '.' + pl).encode(), h).digest())
        check(sg == want, "MAC differs, %s sub=%r" % (alg, sub))
if fails == 0:
    print("ok   jwt interop (python hmac/hashlib: HS256, HS384, HS512, both directions)")
sys.exit(1 if fails else 0)
PY
