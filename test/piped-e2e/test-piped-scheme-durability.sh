#!/usr/bin/env bash
# High durability: 16 data + 4 parity → 20 shards, RS(20, 16).
set -euo pipefail
exec "$(cd "$(dirname "$0")" && pwd)/piped-e2e.sh" 16 4 "$@"
