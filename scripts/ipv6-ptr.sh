#!/usr/bin/env bash
# ipv6-ptr.sh — Compute the PTR record label for an IPv6 address.
#
# Usage: ./scripts/ipv6-ptr.sh <ipv6-address> [zone]
#
# Examples:
#   ./scripts/ipv6-ptr.sh 2001:db8:f9:2::13:1
#     → Full PTR: 1.0.0.0.3.1.0.0.0.0.0.0.0.0.0.0.2.0.0.0.9.f.0.0.8.b.d.0.1.0.0.2.ip6.arpa.
#
#   ./scripts/ipv6-ptr.sh 2001:db8:f9:2::13:1 0.0.8.b.d.0.1.0.0.2.ip6.arpa
#     → Zone label: 1.0.0.0.3.1.0.0.0.0.0.0.0.0.0.0.2.0.0.0.9.f.0.0

set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <ipv6-address> [zone-name]" >&2
    exit 1
fi

IPV6="$1"
ZONE="${2:-}"

# Expand IPv6 address to full 32-hex-digit form using Python
EXPANDED=$(python3 -c "
import ipaddress, sys
addr = ipaddress.IPv6Address('$IPV6')
print(addr.exploded.replace(':', ''))
")

if [[ ${#EXPANDED} -ne 32 ]]; then
    echo "Failed to expand IPv6 address: $IPV6" >&2
    exit 1
fi

# Reverse the nibbles and join with dots
REVERSED=$(echo "$EXPANDED" | rev | fold -w1 | paste -sd '.')
FULL_PTR="${REVERSED}.ip6.arpa."

echo "IPv6 address : $IPV6"
echo "Expanded     : $EXPANDED"
echo "Full PTR     : $FULL_PTR"

if [[ -n "$ZONE" ]]; then
    # Strip trailing dot from zone if present
    ZONE="${ZONE%.}"
    ZONE_SUFFIX=".${ZONE}.ip6.arpa."
    ZONE_SUFFIX="${ZONE_SUFFIX//\./\\.}"   # escape dots for sed
    LABEL=$(echo "$FULL_PTR" | sed "s/${ZONE_SUFFIX}//")
    # Also handle the case zone itself ends with ip6.arpa
    CLEAN_ZONE="${ZONE%.ip6.arpa}"
    ZONE_SUFFIX2=".${CLEAN_ZONE}.ip6.arpa."
    ESCAPED=$(echo "$ZONE_SUFFIX2" | sed 's/\./\\./g')
    LABEL=$(echo "$FULL_PTR" | sed "s/${ESCAPED}//")
    echo "Zone label   : $LABEL"
fi
