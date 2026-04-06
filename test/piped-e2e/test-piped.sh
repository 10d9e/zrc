#!/usr/bin/env bash
# Default piped e2e: k=4 data, m=2 parity (see piped-e2e.sh).
# Optional: pass size in GiB as first arg, e.g. ./test/piped-e2e/test-piped.sh 1
set -euo pipefail
exec "$(cd "$(dirname "$0")" && pwd)/piped-e2e.sh" 4 2 "${1:-}"
