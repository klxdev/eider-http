# Changelog

eider-http's versions (semver). Before 1.0 the MAJOR.MINOR is the Eider toolchain's it goes
with (`eider` in eider.toml), the PATCH its own.

## 0.1.0

The first release as a repository of its own, for Eider 0.1. The code is eider-lang's
`packages/http` as of the split (its history is kept), without JSON-RPC:

- Moved out: `http/jsonrpc` is eider-rpc's `rpc/jsonrpc` (with its test); the examples
  went with the frameworks that use them (examples/kvstore to eider-rpc, examples/todo to
  eider-openapi); docs/services.md came along without the JSON-RPC parts.
- json is a git dependency (eider-json 0.1.0); the fuzz test carries its PRNG
  (tests/rng.ei) instead of depending on eider-lang's packages/fuzz.
- `VERSION`, `eider = "0.1"`, `scripts/build.sh` and `scripts/test.sh` against an eider-lang
  checkout (`EIDER_ROOT`), refusing a toolchain of another MAJOR.MINOR, with
  `EIDER_PKG_OVERRIDE` set for sibling checkouts (scripts/env.sh).
