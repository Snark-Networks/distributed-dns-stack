#!/usr/bin/env bash
# check-zones.sh — Validate all zone files before deployment.
#
# Requires: bind9utils (named-checkzone)
#   Ubuntu: apt install bind9utils
#   macOS:  brew install bind
#
# Usage: ./scripts/check-zones.sh

set -euo pipefail

ZONES_DIR="${1:-zones}"
ERRORS=0

if ! command -v named-checkzone &>/dev/null; then
    echo "ERROR: named-checkzone not found. Install bind9utils." >&2
    exit 1
fi

echo "Checking zone files in ${ZONES_DIR}/..."
echo ""

for f in "${ZONES_DIR}"/db.*; do
    [[ -f "$f" ]] || continue
    # Derive zone name from filename: db.2.0.192.in-addr.arpa → 2.0.192.in-addr.arpa
    zone=$(basename "$f" | sed 's/^db\.//')
    printf "  %-50s " "$zone"
    if named-checkzone "$zone" "$f" &>/dev/null; then
        echo "OK"
    else
        echo "FAIL"
        named-checkzone "$zone" "$f" 2>&1 | sed 's/^/    /'
        (( ERRORS++ )) || true
    fi
done

echo ""
if (( ERRORS > 0 )); then
    echo "FAILED: ${ERRORS} zone(s) have errors." >&2
    exit 1
else
    echo "All zones passed."
fi
