#!/usr/bin/env bash
# Archival / maximum protection (among these presets): 8 data + 4 parity → 12 shards, RS(12, 8).
set -euo pipefail
exec "$(cd "$(dirname "$0")" && pwd)/piped-e2e.sh" 8 4 "$@"
