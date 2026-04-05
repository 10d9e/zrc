# rs — Reed-Solomon erasure codec

**Latest release: [v0.1.0](CHANGELOG.md)** — `rs version` / `rs --version`

A fully self-contained command-line tool written in Zig that splits any file
into **n = k + m** shards using a systematic Reed-Solomon code over GF(2⁸).
Any **k** of the **n** shards are sufficient to reconstruct the original file.

---

## Build

```sh
zig build                        # debug binary  → zig-out/bin/rs
zig build -Doptimize=ReleaseFast # fast optimised binary
zig build test                   # run unit tests
zig build e2e                    # CLI e2e: sizes 10 MiB–1 GiB, encode/decode timings (needs python3)
zig build e2e -De2e-quick=true   # e2e: only 10 MiB and 100 MiB
```

## Quickstart
```sh
dd if=/dev/zero of=testfile.bin bs=1M count=10
./zig-out/bin/rs encode testfile.bin --data 4 --parity 2 --out shards/
./zig-out/bin/rs decode testfile.bin.recovered shards/testfile.bin.shard000 shards/testfile.bin.shard001 shards//testfile.bin.shard002 shards//testfile.bin.shard005
sha256 testfile.bin && sha256 testfile.bin.recovered
```

Requires **Zig 0.15** or later.

---

## Commands

### `encode` — split a file into shards

```
rs encode <file> [--data K] [--parity M] [--out DIR]
```

| Option | Default | Meaning |
|--------|---------|---------|
| `--data K`   | 6 | Number of data shards |
| `--parity M` | 4 | Number of parity shards |
| `--out DIR`  | `.` | Output directory |

Constraints: K ≥ 1, M ≥ 1, K + M ≤ 255.

Produces `<DIR>/<file>.shard000` … `<DIR>/<file>.shard<K+M-1>`.

**Example**

```sh
rs encode photo.jpg --data 4 --parity 2 --out shards/
#   shards/photo.jpg.shard000  [data]
#   shards/photo.jpg.shard001  [data]
#   shards/photo.jpg.shard002  [data]
#   shards/photo.jpg.shard003  [data]
#   shards/photo.jpg.shard004  [parity]
#   shards/photo.jpg.shard005  [parity]
#   → any 4 of 6 shards recover the file
```

---

### `decode` — recover a file from ≥ k shards

```
rs decode <output_file> <shard1> [shard2 …]
rs decode <output_file> -
```

Provide **at least K** shard files. Shards may be in any order and their
indices do not need to be contiguous — any K-subset works.

With **`decode <out> -`**, read **exactly K** shard files from **stdin**, one after
another (e.g. `cat shard000 shard002 … | rs decode out -`). Each shard must be
the full on-disk format (magic + header + payload); payload size is taken from
the header so there is no per-shard size limit.

**Example** (two shards lost, any 4 survive)

```sh
rs decode photo.jpg  shards/photo.jpg.shard000 \
                     shards/photo.jpg.shard002 \
                     shards/photo.jpg.shard004 \
                     shards/photo.jpg.shard005
```

---

### `info` — inspect shard metadata

```
rs info <shard> [shard …]
```

Prints the scheme parameters, shard type (data / parity), and sizes without
loading the full file.

---

### `verify` — re-encode and check parity consistency

```
rs verify <shard0> <shard1> … (all n shards)
```

Re-derives parity shards from the data shards and compares them byte-by-byte
against the stored parity shards. Useful for detecting silent corruption.

---

## Shard file format

```
Offset  Len  Field
------  ---  -----
     0    4  Magic  "RS\x01\x00"
     4    1  k      data-shard count  (u8)
     5    1  m      parity-shard count (u8)
     6    1  index  this shard's 0-based position (u8)
     7    1  (reserved / padding)
     8    8  file_size  original file length (u64 LE)
    16    N  shard_data
```

All shards from the same encoding have identical `k`, `m`, and `file_size`
fields, making it easy to detect mismatched shards.

---

## Algorithm

The codec implements a **systematic (n, k) Reed-Solomon code** over GF(2⁸)
with primitive polynomial `x⁸ + x⁴ + x³ + x² + 1` (0x11D).

### Encoding

1. Build an `n × k` Vandermonde matrix **V** with evaluation points
   `α⁰, α¹, …, α^(n-1)` where `α = 2` is the primitive element of GF(2⁸).
2. Extract the top-k square sub-matrix **V_top** and invert it.
3. Compute the systematic encoding matrix **E = V × V_top⁻¹**.
   The first k rows of **E** equal the identity, so data shards pass
   through unchanged (systematic property).
4. Parity shard `i` (for `i ≥ k`) is computed as the matrix-vector product
   of row `i` of **E** with the data column at each byte position.

### Decoding

1. From the k available shard indices, extract the corresponding k rows of
   **E** to form a k × k sub-matrix **E_sub**.
2. Invert **E_sub** using Gauss-Jordan elimination over GF(2⁸).
3. Multiply **E_sub⁻¹** by the received shard data to recover the original
   k data shards.

The Vandermonde construction guarantees that **any** k rows of **E** form an
invertible matrix, so any k-of-n subset always works.

### Complexity

| Operation | Time |
|-----------|------|
| Matrix inversion | O(k³) |
| Encode one byte column | O(n·k) |
| Decode one byte column | O(k²) |
| Full file encode/decode | O(file_size · n · k) |

For the default (6, 10) scheme, this is fast enough to process hundreds of
MiB/s on modern hardware even in Zig's debug build.

---

## Limits

- Maximum total shards: **255** (GF(2⁸) has 255 non-zero elements).
