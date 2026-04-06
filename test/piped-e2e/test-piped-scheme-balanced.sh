#!/usr/bin/env bash
# Balanced (standard): 10 data + 6 parity → 16 shards total, RS(16, 10).
set -euo pipefail
exec "$(cd "$(dirname "$0")" && pwd)/piped-e2e.sh" 10 6 "$@"
