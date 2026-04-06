#!/bin/bash
set -euo pipefail

DATA_SHARDS=10
PARITY_SHARDS=6
TOTAL_SHARDS=$((DATA_SHARDS + PARITY_SHARDS))
FILE_SIZE_GIB=1

# Randomize line order (portable: BSD/macOS sort -R; no GNU shuf).
shuffle_lines() {
	sort -R
}

# Read stdin into bash array named $1 (one element per line; empty lines skipped).
read_lines_into() {
	local __name=$1
	eval "$__name=()"
	while IFS= read -r __line || [[ -n "${__line:-}" ]]; do
		[[ -n "$__line" ]] || continue
		eval "$__name+=(\"\$__line\")"
	done
}

# Files larger than 1 GiB use two-pass streaming (constant RAM). For a 5 GiB example:
#   dd if=/dev/urandom of=big.bin bs=1M count=5120
#   ./zig-out/bin/rs encode big.bin --data 4 --parity 2 --out shards/
dd if=/dev/urandom of=testfile.bin bs=1G count="$FILE_SIZE_GIB"
time ./zig-out/bin/rs encode testfile.bin --data "$DATA_SHARDS" --parity "$PARITY_SHARDS" --out shards/

# Decode with exactly k shards: include all parity shards + (k - m) random data shards,
# then shuffle order (portable: sort -R; no GNU shuf on macOS).
DECODE_SHARDS=()

for ((i = DATA_SHARDS; i < TOTAL_SHARDS; i++)); do
	DECODE_SHARDS+=("shards/testfile.bin.shard$(printf '%03d' "$i")")
done

# Pick (DATA_SHARDS - PARITY_SHARDS) random distinct data shard indices 0 .. DATA_SHARDS-1
NEED_DATA=$((DATA_SHARDS - PARITY_SHARDS))
read_lines_into PICKED < <(seq 0 $((DATA_SHARDS - 1)) | shuffle_lines | head -n "$NEED_DATA")

for i in "${PICKED[@]}"; do
	DECODE_SHARDS+=("shards/testfile.bin.shard$(printf '%03d' "$i")")
done

read_lines_into SHUFFLED < <(printf '%s\n' "${DECODE_SHARDS[@]}" | shuffle_lines)

echo "Decoding with ${#SHUFFLED[@]} shards (order shuffled):"
printf '  %s\n' "${SHUFFLED[@]}"

time ./zig-out/bin/rs decode testfile.bin.recovered "${SHUFFLED[@]}"
sha256sum testfile.bin && sha256sum testfile.bin.recovered
cmp -s testfile.bin testfile.bin.recovered

# cleanup
rm -f testfile.bin testfile.bin.recovered
rm -rf shards/
