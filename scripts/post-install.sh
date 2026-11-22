#!/usr/bin/env bash
# Run once on the Docker host, after MISP's first start:
#   - enables the taxonomies zsazsa and misp-scraper tag with
#   - creates a MISP user with its own API key for zsazsa and for misp-scraper
#     (role Org Admin), each key only valid from the address that tool calls from
#   - puts those keys in their configuration in place of the administrator's
#     key, and restarts them
# Safe to run again: existing users are left alone, unless --new-keys.
#
#   bash scripts/post-install.sh [--new-keys] [--no-ip-limit]
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

NEW_KEYS=0
IP_LIMIT=1
for arg in "$@"; do
    case "$arg" in
        --new-keys) NEW_KEYS=1 ;;
        --no-ip-limit) IP_LIMIT=0 ;;
        *) die "Unknown option $arg. Usage: bash scripts/post-install.sh [--new-keys] [--no-ip-limit]" ;;
    esac
done

[[ -f "$MISP_ENV" && -f "$ZSAZSA_CFG" && -f "$SCRAPER_CFG" ]] || die "Run scripts/init.sh first."
command -v docker > /dev/null || die "Run this on the Docker host."

# TLP 2.0 only: tlp:white, tlp:ex:chr and tlp:unclear stay off (and are hidden if they exist).
TAXONOMIES="tlp=tlp:red,tlp:amber,tlp:amber+strict,tlp:green,tlp:clear workflow admiralty-scale cti-evaluation"
ADMIN_EMAIL="$(get_env "$MISP_ENV" ADMIN_EMAIL)"
ADMIN_KEY="$(get_env "$MISP_ENV" ADMIN_KEY)"
HTTPS_PORT="$(get_env "$MISP_ENV" MISP_HTTPS_PORT)"

# zsazsa calls MISP through the reverse proxy, so MISP sees the Docker host's
# address; misp-scraper calls misp-nginx directly, from misp-docker's network.
ZSAZSA_FROM="" SCRAPER_FROM=""
if [[ "$IP_LIMIT" == 1 ]]; then
    LAN_PARENT="$(get_env "$SETTINGS" LAN_PARENT)"
    HOST_IP="$(ip -4 -o addr show dev "${LAN_PARENT:-eth0}" | awk '{ sub("/.*", "", $4); print $4; exit }')"
    BRIDGE="$(docker network inspect misp-docker_default -f '{{range .IPAM.Config}}{{.Subnet}} {{end}}' | awk '{ print $1 }')"
    [[ -n "$HOST_IP" && -n "$BRIDGE" ]] || die "Could not determine the Docker host's address or misp-docker's network; use --no-ip-limit."
    ZSAZSA_FROM="$HOST_IP/32"
    SCRAPER_FROM="$BRIDGE"
fi

# Plus addresses: unique in MISP, delivered to the administrator's mailbox.
LOCAL="${ADMIN_EMAIL%@*}"
DOMAIN="${ADMIN_EMAIL#*@}"
USERS="zsazsa=$LOCAL+zsazsa@$DOMAIN=$ZSAZSA_FROM scraper=$LOCAL+scraper@$DOMAIN=$SCRAPER_FROM"

info "MISP: taxonomies, users and API keys"
OUTPUT="$(cd "$MISP_DIR" && docker compose exec -T \
    -e MISP_URL="https://misp-nginx:${HTTPS_PORT:-8443}" \
    -e TAXONOMIES="$TAXONOMIES" -e USERS="$USERS" -e ROLE="Org Admin" -e NEW_KEYS="$NEW_KEYS" \
    misp-core python3 - < "$ROOT/deploy/misp/post_install.py")"
grep -v '^KEY ' <<< "$OUTPUT" | sed 's/^/    /'

ZSAZSA_KEY="$(awk '$1 == "KEY" && $2 == "zsazsa" { print $3 }' <<< "$OUTPUT")"
SCRAPER_KEY="$(awk '$1 == "KEY" && $2 == "scraper" { print $3 }' <<< "$OUTPUT")"

info "zsazsa and misp-scraper configuration"
if [[ -n "$ZSAZSA_KEY" ]]; then
    set_py "$ZSAZSA_CFG" MISP_KEY "'$ZSAZSA_KEY'"
    set_py "$ZSAZSA_CFG" MISP_WEBAPP_KEY "'$ZSAZSA_KEY'"
    echo "    zsazsa: new key set (MISP_KEY, MISP_WEBAPP_KEY)"
fi
if [[ -n "$SCRAPER_KEY" ]]; then
    set_py "$SCRAPER_CFG" misp_key "\"$SCRAPER_KEY\""
    echo "    misp-scraper: new key set (misp_key)"
fi
own_volumes

if grep -qF "$ADMIN_KEY" "$ZSAZSA_CFG" "$SCRAPER_CFG"; then
    warn "The administrator's key is still in use: $(grep -lF "$ADMIN_KEY" "$ZSAZSA_CFG" "$SCRAPER_CFG" | xargs -n1 basename | xargs). Run again with --new-keys."
fi

if [[ -n "$ZSAZSA_KEY$SCRAPER_KEY" ]]; then
    info "Restarting zsazsa and misp-scraper"
    (cd "$ZSAZSA_DIR" && docker compose restart)
fi
echo
echo "Done. MISP lists the users under Administration > List Users; their keys under each user's Auth keys."
