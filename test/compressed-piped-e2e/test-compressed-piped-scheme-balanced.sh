#!/usr/bin/env bash
# RS(16, 10): k=10, m=6.
set -euo pipefail
exec "$(cd "$(dirname "$0")" && pwd)/compressed-piped-e2e.sh" 10 6 "$@"
