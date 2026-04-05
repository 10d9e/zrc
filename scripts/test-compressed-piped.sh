#!/bin/bash
set -euo pipefail

# Same as test-piped.sh, but the byte stream is gzip-compressed end-to-end:
#   plaintext → gzip → rs encode → shards → rs decode → gzip payload → gunzip → plaintext
#
# Files larger than 1 GiB use two-pass streaming (constant RAM). For a 5 GiB example:
#   dd if=/dev/zero of=big.bin bs=1M count=5120
#   gzip -c big.bin | ./zig-out/bin/rs encode - --data 4 --parity 2 --out shards/
dd if=/dev/zero of=testfile.bin bs=1G count=5

TIMEFORMAT=$'encode: %R s wall (%U s user, %S s sys)\n'
echo "Timing stdin → gzip → encode (spool + shard write)…"
time gzip -c testfile.bin | ./zig-out/bin/rs encode - --data 4 --parity 2 --out shards/

TIMEFORMAT=$'decode | gunzip: %R s wall (%U s user, %S s sys)\n'
echo "Timing concat shards → decode (stdout) | gunzip → plaintext…"
time cat shards/stdin.shard000 shards/stdin.shard001 shards/stdin.shard002 shards/stdin.shard005 \
  | ./zig-out/bin/rs decode - - \
  | gunzip -c >testfile.bin.recovered
unset TIMEFORMAT
sha256sum testfile.bin && sha256sum testfile.bin.recovered
cmp -s testfile.bin testfile.bin.recovered

# Compressed stdin example:
# dd if=/dev/zero bs=1G count=2 | gzip -c | ./zig-out/bin/rs encode - --data 4 --parity 2 --out shards/

rm -f testfile.bin testfile.bin.recovered
rm -rf shards/
