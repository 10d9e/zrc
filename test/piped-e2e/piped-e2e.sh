#!/usr/bin/env bash
# Streaming encode/decode e2e: stdin spool → k data + m parity shards → decode with k shards
# (k−1 data indices 0..k−2 plus last parity index k+m−1; k=1 uses only shard 000). Run from repo root.
#
# Wrappers in this directory: test-piped.sh, test-piped-k*.sh, test-piped-scheme-*.sh
# Gzip-through-encode variant: ../compressed-piped-e2e/
#
# usage: ./test/piped-e2e/piped-e2e.sh <k> <m> [size_gib]
# env:   RS_BIN   path to rs (default: <repo>/zig-out/bin/rs)
#        SIZE_GIB default for 3rd arg if omitted (default 5)

set -euo pipefail

usage() {
	echo "usage: $(basename "$0") <data_k> <parity_m> [size_gib]" >&2
	echo "  env RS_BIN, SIZE_GIB" >&2
	exit 1
}

[[ $# -ge 2 ]] || usage
K="$1"
M="$2"
SIZE_GIB="${3:-${SIZE_GIB:-1}}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$SCRIPT_DIR"
while [[ "$REPO_ROOT" != "/" && ! -f "$REPO_ROOT/build.zig" ]]; do
	REPO_ROOT="$(dirname "$REPO_ROOT")"
done
if [[ ! -f "$REPO_ROOT/build.zig" ]]; then
	echo "error: could not find repo root (build.zig) above $SCRIPT_DIR" >&2
	exit 1
fi
RS_BIN="${RS_BIN:-$REPO_ROOT/zig-out/bin/rs}"

if [[ ! -f "$RS_BIN" ]]; then
	echo "error: rs binary not found: $RS_BIN (zig build first or set RS_BIN)" >&2
	exit 1
fi

if ((M > K)); then
	echo "error: m must be ≤ k (got k=$K m=$M)" >&2
	exit 1
fi
if ((K + M > 255)); then
	echo "error: k+m must be ≤ 255 (got $((K + M)))" >&2
	exit 1
fi

N=$((K + M))
echo "piped-e2e: k=$K m=$M (n=$N), ${SIZE_GIB} GiB random data, rs=$RS_BIN"
echo

dd if=/dev/urandom of=testfile.bin bs=1G count="$SIZE_GIB"

TIMEFORMAT=$'encode: %R s wall (%U s user, %S s sys)\n'
echo "Timing stdin → encode (spool + shard write)…"
time "$RS_BIN" encode - --data "$K" --parity "$M" --out shards/ <testfile.bin

DECODE_SHARDS=()
if ((K == 1)); then
	# Single data shard is enough to recover.
	DECODE_SHARDS=("shards/stdin.shard000")
else
	for ((i = 0; i <= K - 2; i++)); do
		DECODE_SHARDS+=("shards/stdin.shard$(printf '%03d' "$i")")
	done
	DECODE_SHARDS+=("shards/stdin.shard$(printf '%03d' "$((K + M - 1))")")
fi

TIMEFORMAT=$'decode: %R s wall (%U s user, %S s sys)\n'
if ((K == 1)); then
	echo "Timing decode (1 shard path: data 0)…"
else
	echo "Timing decode (${#DECODE_SHARDS[@]} shard paths: data 0..$((K - 2)) + parity $((K + M - 1)))…"
fi
time "$RS_BIN" decode testfile.bin.recovered "${DECODE_SHARDS[@]}"
unset TIMEFORMAT

sha256sum testfile.bin testfile.bin.recovered
cmp -s testfile.bin testfile.bin.recovered

rm -f testfile.bin testfile.bin.recovered
rm -rf shards/

echo "OK: piped e2e k=$K m=$M"
