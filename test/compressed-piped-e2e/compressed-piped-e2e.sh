#!/usr/bin/env bash
# End-to-end: plaintext file → compress → rs encode - (spool + shards) → rs decode (stdout) → decompress → cmp
# Same shard choice as piped-e2e (k−1 data indices 0..k−2 + parity k+m−1; k=1 uses shard 000). Run from repo root.
#
# Wrappers: test-compressed-piped.sh, test-compressed-piped-k*.sh, test-compressed-piped-scheme-*.sh
#
# usage: ./test/compressed-piped-e2e/compressed-piped-e2e.sh <k> <m> [size_gib]
# env:   RS_BIN, SIZE_GIB (default 5 for missing 3rd arg)
#
# Uses pigz when available; otherwise gzip -1 / gzip -dc.

set -euo pipefail

usage() {
	echo "usage: $(basename "$0") <data_k> <parity_m> [size_gib]" >&2
	echo "  env RS_BIN, SIZE_GIB" >&2
	exit 1
}

[[ $# -ge 2 ]] || usage
K="$1"
M="$2"
SIZE_GIB="${3:-${SIZE_GIB:-5}}"

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

if command -v pigz >/dev/null 2>&1; then
	GZIP_C=(pigz -c)
	GZIP_D=(pigz -dc)
	COMP_LABEL="pigz"
else
	GZIP_C=(gzip -1 -c)
	GZIP_D=(gzip -dc)
	COMP_LABEL="gzip -1"
fi

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
echo "compressed-piped-e2e: k=$K m=$M (n=$N), ${SIZE_GIB} GiB random data, rs=$RS_BIN, compress=$COMP_LABEL"
echo

dd if=/dev/urandom of=testfile.bin bs=1G count="$SIZE_GIB"

TIMEFORMAT=$'encode: %R s wall (%U s user, %S s sys)\n'
echo "Timing ${COMP_LABEL} → stdin → encode (spool + shard write)…"
time "${GZIP_C[@]}" testfile.bin | "$RS_BIN" encode - --data "$K" --parity "$M" --out shards/

DECODE_SHARDS=()
if ((K == 1)); then
	DECODE_SHARDS=("shards/stdin.shard000")
else
	for ((i = 0; i <= K - 2; i++)); do
		DECODE_SHARDS+=("shards/stdin.shard$(printf '%03d' "$i")")
	done
	DECODE_SHARDS+=("shards/stdin.shard$(printf '%03d' "$((K + M - 1))")")
fi

TIMEFORMAT=$'decode | decompress: %R s wall (%U s user, %S s sys)\n'
if ((K == 1)); then
	echo "Timing decode (stdout | ${COMP_LABEL} decompress) — 1 shard: data 0…"
else
	echo "Timing decode (stdout | ${COMP_LABEL} decompress) — ${#DECODE_SHARDS[@]} shards: data 0..$((K - 2)) + parity $((K + M - 1))…"
fi
time "$RS_BIN" decode - "${DECODE_SHARDS[@]}" | "${GZIP_D[@]}" >testfile.bin.recovered
unset TIMEFORMAT

sha256sum testfile.bin testfile.bin.recovered
cmp -s testfile.bin testfile.bin.recovered

rm -f testfile.bin testfile.bin.recovered
rm -rf shards/

echo "OK: compressed piped e2e k=$K m=$M"
