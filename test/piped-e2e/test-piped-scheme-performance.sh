#!/usr/bin/env bash
# High performance / lower protection: 10 data + 4 parity → 14 shards, RS(14, 10).
set -euo pipefail
exec "$(cd "$(dirname "$0")" && pwd)/piped-e2e.sh" 10 4 "$@"
