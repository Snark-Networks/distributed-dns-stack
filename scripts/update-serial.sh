#!/usr/bin/env bash
# update-serial.sh — Bump the SOA serial in one or all zone files.
#
# Usage:
#   ./scripts/update-serial.sh                  # update all zones/db.* files
#   ./scripts/update-serial.sh zones/db.foo     # update a specific file
#
# Serial format: YYYYMMDDnn
#   - Date part resets nn to 01 on a new day
#   - Same-day edits increment nn (up to 99)

set -euo pipefail

TODAY=$(date +%Y%m%d)

bump_serial() {
    local file="$1"
    local current_serial
    current_serial=$(grep -i 'Serial' "$file" | grep -oP '\d{10}' | head -1)

    if [[ -z "$current_serial" ]]; then
        echo "  [SKIP] No serial found in $file" >&2
        return
    fi

    local serial_date="${current_serial:0:8}"
    local serial_nn="${current_serial:8:2}"

    if [[ "$serial_date" == "$TODAY" ]]; then
        local new_nn
        new_nn=$(printf "%02d" $(( 10#$serial_nn + 1 )))
        if (( 10#$new_nn > 99 )); then
            echo "  [ERROR] Serial counter overflow in $file (nn=99). Edit manually." >&2
            return 1
        fi
        local new_serial="${TODAY}${new_nn}"
    else
        local new_serial="${TODAY}01"
    fi

    # In-place replacement (macOS and GNU sed compatible)
    sed -i.bak "s/${current_serial}/${new_serial}/" "$file"
    rm -f "${file}.bak"
    echo "  [OK] $file: $current_serial → $new_serial"
}

if [[ $# -ge 1 ]]; then
    for f in "$@"; do
        echo "Updating serial: $f"
        bump_serial "$f"
    done
else
    echo "Updating SOA serials in all zone files..."
    shopt -s nullglob
    for f in zones/db.*; do
        bump_serial "$f"
    done
fi
