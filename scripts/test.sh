#!/bin/bash
set -euo pipefail

# Files larger than 1 GiB use two-pass streaming (constant RAM). For a 5 GiB example:
#   dd if=/dev/zero of=big.bin bs=1M count=5120
#   ./zig-out/bin/rs encode big.bin --data 4 --parity 2 --out shards/
dd if=/dev/zero of=testfile.bin bs=1M count=20
./zig-out/bin/rs encode testfile.bin --data 4 --parity 2 --out shards/
./zig-out/bin/rs decode testfile.bin.recovered \
  shards/testfile.bin.shard000 shards/testfile.bin.shard001 shards/testfile.bin.shard002 shards/testfile.bin.shard005
sha256sum testfile.bin && sha256sum testfile.bin.recovered
cmp -s testfile.bin testfile.bin.recovered

# cleanup
rm -f testfile.bin testfile.bin.recovered
rm -rf shards/
