# Changelog

## v0.1.0 — 2026-04-05

First release.

- Systematic Reed–Solomon **(k, n)** over **GF(2⁸)** with CLI: `encode`, `decode`, `info`, `verify`.
- **Encode**: configurable `--data` / `--parity`, shard files under `--out`; inputs **> 1 GiB** use a **streaming** two-pass encoder; **`encode -`** reads stdin (spool then encode).
- **Decode**: any **k** shards; **`decode <out> -`** reads **k** concatenated shard blobs from stdin.
- **Performance**: multiply **LUT**, SIMD-style wide **XOR** where applicable, **threaded** parity / decode / streaming parity chunks.
- **Tests**: `zig build test`, optional `zig build e2e` (Python).

Requires **Zig 0.15** or later.
