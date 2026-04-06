#!/usr/bin/env bash
# Default compressed piped e2e: k=4, m=2. Optional first arg = size GiB (e.g. 1).
set -euo pipefail
exec "$(cd "$(dirname "$0")" && pwd)/compressed-piped-e2e.sh" 4 2 "${1:-}"
