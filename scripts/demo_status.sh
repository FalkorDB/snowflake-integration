#!/bin/bash

# Show what is running — and therefore what is billing — for the FalkorDB demo.
#
# Usage: ./scripts/demo_status.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/demo_common.sh
source "$SCRIPT_DIR/demo_common.sh"

echo "📊 FalkorDB Demo Status"
echo "======================="
print_config
echo ""

echo "🖥️  Compute pool"
state="$(compute_pool_state)"
state_upper="$(printf '%s' "$state" | tr '[:lower:]' '[:upper:]')"

case "$state_upper" in
    SUSPENDED|STOPPING|SUSPENDING)
        echo "   ${POOL_NAME}: ${state_upper} — not billing ✅"
        ;;
    "")
        echo "   ${POOL_NAME}: unknown (role ${APP_ROLE} cannot see it, or it does not exist)"
        ;;
    *)
        # ACTIVE and IDLE both keep nodes provisioned, and both bill per node-hour.
        echo "   ${POOL_NAME}: ${state_upper} — BILLING per node-hour ⚠️"
        ;;
esac
echo ""

echo "🐳 Service app_public.st_spcs"
statuses="$(service_statuses)"
echo "   Status: ${statuses:-unknown}"
echo ""

echo "🌐 FalkorDB Browser"
url="$(browser_url)"
if [ -n "$url" ]; then
    echo "   https://${url#https://}"
else
    echo "   Not available (service not ready)"
fi
echo ""

case "$state_upper" in
    SUSPENDED|STOPPING|SUSPENDING|"") ;;
    *)
        echo "💡 Stop the bill with: ./scripts/demo_stop.sh"
        echo ""
        ;;
esac
