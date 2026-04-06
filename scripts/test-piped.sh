#!/bin/bash
set -euo pipefail

# Files larger than 1 GiB use two-pass streaming (constant RAM). For a 5 GiB example:
#   dd if=/dev/zero of=big.bin bs=1M count=5120
#   ./zig-out/bin/rs encode big.bin --data 4 --parity 2 --out shards/
dd if=/dev/zero of=testfile.bin bs=1G count=5

TIMEFORMAT=$'encode: %R s wall (%U s user, %S s sys)\n'
echo "Timing stdin → encode (spool + shard write)…"
time ./zig-out/bin/rs encode - --data 4 --parity 2 --out shards/ < testfile.bin

TIMEFORMAT=$'decode: %R s wall (%U s user, %S s sys)\n'
echo "Timing decode (k shard paths; faster than cat … | rs decode … -)…"
time ./zig-out/bin/rs decode testfile.bin.recovered \
  shards/stdin.shard000 shards/stdin.shard001 shards/stdin.shard002 shards/stdin.shard005
unset TIMEFORMAT
sha256sum testfile.bin && sha256sum testfile.bin.recovered
cmp -s testfile.bin testfile.bin.recovered

# Stdin example (spools to a temp file under --out, then encodes):
# dd if=/dev/zero bs=1G count=2 | ./zig-out/bin/rs encode - --data 4 --parity 2 --out shards/
#
# If you must feed k shards as one stdin stream (slower: cat + pipe + sequential read):
#   cat s0 s1 s2 s5 | ./zig-out/bin/rs decode out -

rm -f testfile.bin testfile.bin.recovered
rm -rf shards/
