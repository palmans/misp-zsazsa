#!/usr/bin/env bash
# Prepares this deployment from deploy/settings.env:
#   - misp-docker/.env, with generated passwords and keys
#   - a self-signed certificate for misp-nginx in misp-docker/ssl/
#   - zsazsa/docker/.env
#   - the zsazsa and misp-scraper configuration in zsazsa/docker/volumes/
#   - the Docker network that puts misp-nginx on the LAN
#
# Safe to run again: the settings are applied to the .env files again, but
# passwords, keys, the certificate and the zsazsa and misp-scraper
# configuration are only created when they are missing.
#
#   bash scripts/init.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETTINGS="$ROOT/deploy/settings.env"
MISP_DIR="$ROOT/misp-docker"
MISP_ENV="$MISP_DIR/.env"
ZSAZSA_DIR="$ROOT/zsazsa/docker"
ZSAZSA_ENV="$ZSAZSA_DIR/.env"
VOL="$ZSAZSA_DIR/volumes"

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARNING:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

is_root() { [[ "$(id -u)" == 0 ]]; }
on_linux() { [[ "$(uname -s)" == Linux ]]; }

# Letters and digits only: nothing to escape in .env, Redis URLs or Python.
rand() { openssl rand -base64 192 | tr -dc 'A-Za-z0-9' | cut -c "1-$1"; }

# Value of the active KEY= line in a .env file, without quotes.
get_env() {
    local v
    v=$(grep -E "^$2=" "$1" 2> /dev/null | tail -n 1 | cut -d= -f2-) || true
    v="${v%\"}"
    printf '%s' "${v#\"}"
}

# Replaces the first KEY= line, commented out or not, or appends one.
set_env() {
    local file=$1 key=$2 val=$3
    [[ "$val" == *[[:space:]]* ]] && val="\"$val\""
    awk -v k="$key" -v line="$key=$val" '
        !done && $0 ~ "^[#[:space:]]*" k "=" { print line; done = 1; next }
        { print }
        END { if (!done) print line }
    ' "$file" > "$file.tmp"
    mv "$file.tmp" "$file"
}

# Sets KEY only while it has no value.
set_secret() {
    if [[ -z "$(get_env "$1" "$2")" ]]; then
        set_env "$1" "$2" "$(rand "$3")"
    fi
}

# Replaces the line assigning KEY in a Python config file; VALUE is a literal.
set_py() {
    local file=$1 key=$2 val=$3
    awk -v k="$key" -v line="$key = $val" '
        !done && $0 ~ "^" k "[[:space:]]*=" { print line; done = 1; next }
        { print }
        END { if (!done) print line }
    ' "$file" > "$file.tmp"
    mv "$file.tmp" "$file"
}

# --- Settings ----------------------------------------------------------------

[[ -f "$SETTINGS" ]] || die "deploy/settings.env not found. Copy deploy/settings.env.example to deploy/settings.env and fill it in."
command -v openssl > /dev/null || die "openssl is required."

# KEY=VALUE lines, read rather than sourced: values may contain spaces.
while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
    [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || die "Cannot read this line of deploy/settings.env: $line"
    key="${BASH_REMATCH[1]}"
    val="${BASH_REMATCH[2]}"
    val="${val%\"}"
    val="${val#\"}"
    printf -v "$key" '%s' "$val"
done < "$SETTINGS"

for var in MISP_HOSTNAME ADMIN_EMAIL ADMIN_ORG MISP_LAN_IP LAN_PARENT LAN_SUBNET LAN_GATEWAY LAN_IP_RANGE PROXY_IP; do
    [[ -n "${!var:-}" ]] || die "Set $var in deploy/settings.env."
done
TZ="${TZ:-UTC}"
MISP_HTTPS_PORT="${MISP_HTTPS_PORT:-8443}"
MISP_HTTP_PORT="${MISP_HTTP_PORT:-8080}"
LAN_NETWORK_NAME="${LAN_NETWORK_NAME:-cti-lan}"
LAN_DRIVER="${LAN_DRIVER:-ipvlan}"
case "${PROXY_CERT_VALID:-true}" in
    true | True | yes | 1) VERIFYCERT=True ;;
    *) VERIFYCERT=False ;;
esac

chmod +x "$ROOT/deploy/nginx/05-zsazsa.sh" "$ROOT/deploy/misp/customize_misp.sh" "$ROOT"/scripts/*.sh

# --- misp-docker -------------------------------------------------------------

info "misp-docker/.env"
if [[ ! -f "$MISP_ENV" ]]; then
    cp "$MISP_DIR/template.env" "$MISP_ENV"
    echo "    created from template.env"
fi

for tag in CORE_TAG MODULES_TAG GUARD_TAG; do
    set_env "$MISP_ENV" "$tag" "$(get_env "$MISP_DIR/template.env" "$tag")"
done
set_env "$MISP_ENV" CORE_RUNNING_TAG "$(get_env "$MISP_DIR/template.env" CORE_TAG)"
set_env "$MISP_ENV" MODULES_RUNNING_TAG "$(get_env "$MISP_DIR/template.env" MODULES_TAG)"
set_env "$MISP_ENV" COMPOSE_PROJECT_NAME misp-docker
set_env "$MISP_ENV" COMPOSE_FILE "docker-compose.yml:../deploy/misp-docker.override.yml"
set_env "$MISP_ENV" BASE_URL "https://$MISP_HOSTNAME"
set_env "$MISP_ENV" ADMIN_EMAIL "$ADMIN_EMAIL"
set_env "$MISP_ENV" ADMIN_ORG "$ADMIN_ORG"
set_env "$MISP_ENV" TZ "$TZ"
set_env "$MISP_ENV" DISABLE_PRINTING_PLAINTEXT_CREDENTIALS true
set_env "$MISP_ENV" NGINX_X_FORWARDED_FOR true
set_env "$MISP_ENV" NGINX_SET_REAL_IP_FROM "$PROXY_IP"
set_env "$MISP_ENV" MISP_LAN_IP "$MISP_LAN_IP"
set_env "$MISP_ENV" MISP_HTTPS_PORT "$MISP_HTTPS_PORT"
set_env "$MISP_ENV" MISP_HTTP_PORT "$MISP_HTTP_PORT"
set_env "$MISP_ENV" LAN_NETWORK_NAME "$LAN_NETWORK_NAME"

# Fixed after the first start: the database and MISP are initialised with them.
set_secret "$MISP_ENV" MYSQL_PASSWORD 32
set_secret "$MISP_ENV" MYSQL_ROOT_PASSWORD 32
set_secret "$MISP_ENV" REDIS_PASSWORD 32
set_secret "$MISP_ENV" ADMIN_PASSWORD 32
set_secret "$MISP_ENV" ADMIN_KEY 40
set_secret "$MISP_ENV" ENCRYPTION_KEY 32
set_secret "$MISP_ENV" GPG_PASSPHRASE 32
set_secret "$MISP_ENV" SUPERVISOR_PASSWORD 32
# Optional variables docker-compose.yml uses without a default. Empty behaves
# the same as unset, without a warning per variable on every compose command.
if ! grep -q '^# --- Optional settings left empty' "$MISP_ENV"; then
    printf '\n# --- Optional settings left empty (by scripts/init.sh): set a value here or remove the line ---\n' >> "$MISP_ENV"
fi
for var in $(grep -oE '(^|[^$])\$\{[A-Za-z0-9_]+\}' "$MISP_DIR/docker-compose.yml" | sed -E 's/.*\$\{([A-Za-z0-9_]+)\}/\1/' | sort -u); do
    grep -qE "^$var=" "$MISP_ENV" || echo "$var=" >> "$MISP_ENV"
done
chmod 600 "$MISP_ENV"

# Mail relay. With a user and password but no aliases, the mail container
# would not use them at all: default the aliases to the relay itself.
if [[ -n "$(get_env "$MISP_ENV" SMARTHOST_USER)" && -z "$(get_env "$MISP_ENV" SMARTHOST_ALIASES)" ]]; then
    set_env "$MISP_ENV" SMARTHOST_ALIASES "$(get_env "$MISP_ENV" SMARTHOST_ADDRESS)"
fi
# exim only sends the relay password over TLS, unless this is true.
{
    echo "# Written by scripts/init.sh from SMARTHOST_ALLOW_PLAINTEXT_AUTH in .env"
    if [[ "$(get_env "$MISP_ENV" SMARTHOST_ALLOW_PLAINTEXT_AUTH)" == true ]]; then
        echo "AUTH_CLIENT_ALLOW_NOTLS_PASSWORDS = 1"
    fi
} > "$MISP_DIR/exim-macros"
chmod 644 "$MISP_DIR/exim-macros"

ADMIN_KEY="$(get_env "$MISP_ENV" ADMIN_KEY)"
REDIS_PASSWORD="$(get_env "$MISP_ENV" REDIS_PASSWORD)"

info "misp-docker/ssl (certificate of misp-nginx)"
SSL="$MISP_DIR/ssl"
if [[ -f "$SSL/cert.pem" && -f "$SSL/key.pem" ]]; then
    echo "    kept the existing certificate"
else
    mkdir -p "$SSL"
    # MSYS_NO_PATHCONV keeps Git Bash on Windows from rewriting "/CN=..." as a
    # path, so the output paths have to be relative.
    (cd "$SSL" && MSYS_NO_PATHCONV=1 openssl req -x509 -nodes -newkey rsa:4096 -days 3650 \
        -subj "/CN=$MISP_HOSTNAME" \
        -addext "subjectAltName=DNS:$MISP_HOSTNAME,DNS:misp-nginx,IP:$MISP_LAN_IP" \
        -keyout key.pem -out cert.pem 2> /dev/null)
    echo "    created a self-signed certificate for $MISP_HOSTNAME"
fi
# misp-nginx runs as uid/gid 101 and has to read the key.
chmod 644 "$SSL/cert.pem"
if is_root; then
    chgrp 101 "$SSL/key.pem"
    chmod 640 "$SSL/key.pem"
else
    chmod 644 "$SSL/key.pem"
fi

# --- zsazsa ------------------------------------------------------------------

info "zsazsa/docker/.env"
if [[ ! -f "$ZSAZSA_ENV" ]]; then
    cp "$ZSAZSA_DIR/env.example" "$ZSAZSA_ENV"
    echo "    created from env.example"
fi
set_env "$ZSAZSA_ENV" COMPOSE_FILE "docker-compose.yml:docker-compose.misp-docker.yml:../../deploy/zsazsa.override.yml"
set_env "$ZSAZSA_ENV" COMPOSE_PROFILES "scheduled,scraper"
set_env "$ZSAZSA_ENV" MISP_NETWORK misp-docker_default
set_env "$ZSAZSA_ENV" SCRAPER_DIR ../../misp-scraper
set_env "$ZSAZSA_ENV" REDIS_HOST redis
set_env "$ZSAZSA_ENV" REDIS_PORT 6379
set_env "$ZSAZSA_ENV" REDIS_PASSWORD "$REDIS_PASSWORD"
set_env "$ZSAZSA_ENV" MISP_HOSTNAME "$MISP_HOSTNAME"
set_env "$ZSAZSA_ENV" PROXY_IP "$PROXY_IP"
set_env "$ZSAZSA_ENV" TZ "$TZ"
chmod 600 "$ZSAZSA_ENV"

info "zsazsa/docker/volumes/config/__init__.py"
CFG="$VOL/config/__init__.py"
if [[ -f "$CFG" ]]; then
    echo "    kept the existing configuration (edit it, or use zsazsa's Settings page)"
else
    mkdir -p "$VOL/config" "$VOL/data" "$VOL/prompts"
    cp "$ROOT/zsazsa/config/__init__.py.example" "$CFG"
    set_py "$CFG" SECRET_KEY "'$(rand 64)'"
    set_py "$CFG" MISP_SCRAPER_ENABLED True
    for prefix in MISP MISP_WEBAPP; do
        set_py "$CFG" "${prefix}_URL" "'https://$MISP_HOSTNAME'"
        set_py "$CFG" "${prefix}_KEY" "'$ADMIN_KEY'"
        set_py "$CFG" "${prefix}_VERIFYCERT" "$VERIFYCERT"
    done
    set_py "$CFG" OPENAI_API_KEY "''"
    # MISP's Redis: PHP sessions (single sign-on), the scraper queue and jobs.
    for prefix in MISP_SESSION SCRAPER JOB; do
        set_py "$CFG" "${prefix}_REDIS_HOST" "'redis'"
        set_py "$CFG" "${prefix}_REDIS_PORT" 6379
        set_py "$CFG" "${prefix}_REDIS_PASSWORD" "'$REDIS_PASSWORD'"
    done
    set_py "$CFG" MISP_SESSION_REDIS_DB 0
    set_py "$CFG" MISP_SESSION_REDIRECT_TO_LOGIN True
    echo "    created; MISP API key: the admin key (replace it, see README.md)"
fi

info "zsazsa/docker/volumes/scraper-config (misp-scraper)"
SCR="$VOL/scraper-config/scraper.py"
if [[ -f "$SCR" ]]; then
    echo "    kept the existing configuration"
else
    mkdir -p "$VOL/scraper-config"
    cp "$ZSAZSA_DIR/scraper.py.zsazsa" "$SCR"
    # Straight to misp-nginx on the Docker network; its certificate is self-signed.
    set_py "$SCR" misp_url "\"https://misp-nginx:$MISP_HTTPS_PORT\""
    set_py "$SCR" misp_key "\"$ADMIN_KEY\""
    set_py "$SCR" misp_verifycert False
    set_py "$SCR" flask_secret_key "\"$(rand 64)\""
    # Your organisation only. The defaults point at sharing group 4, which a
    # new MISP does not have.
    set_py "$SCR" misp_distribution 0
    set_py "$SCR" rawhtml_distribution 0
    echo "    created; MISP API key: the admin key (replace it, see README.md)"
fi
[[ -f "$VOL/scraper-config/feedlist.json" ]] || cp "$ROOT/misp-scraper/feedlist.json" "$VOL/scraper-config/feedlist.json"

# The containers run as uid 1000.
chmod 600 "$CFG" "$SCR"
if is_root; then
    chown -R 1000:1000 "$VOL"
elif on_linux && [[ "$(id -u)" != 1000 ]]; then
    warn "Run as root, or chown -R 1000:1000 zsazsa/docker/volumes: the containers run as uid 1000."
fi

# --- LAN network -------------------------------------------------------------

info "Docker network $LAN_NETWORK_NAME ($LAN_DRIVER on $LAN_PARENT)"
NET_OPTS=(-d "$LAN_DRIVER" --subnet "$LAN_SUBNET" --gateway "$LAN_GATEWAY" --ip-range "$LAN_IP_RANGE" -o "parent=$LAN_PARENT")
[[ "$LAN_DRIVER" == ipvlan ]] && NET_OPTS+=(-o ipvlan_mode=l2)
if ! on_linux || ! command -v docker > /dev/null; then
    warn "Not on the Linux Docker host; create the network there with: docker network create ${NET_OPTS[*]} $LAN_NETWORK_NAME"
elif docker network inspect "$LAN_NETWORK_NAME" > /dev/null 2>&1; then
    echo "    exists: $(docker network inspect -f '{{.Driver}} {{range .IPAM.Config}}{{.Subnet}} {{end}}' "$LAN_NETWORK_NAME")"
else
    docker network create "${NET_OPTS[@]}" "$LAN_NETWORK_NAME" > /dev/null
    echo "    created"
fi

cat << EOF

Done. Next steps (see README.md):
  1. cd misp-docker && docker compose pull && docker compose up -d
  2. Point your reverse proxy at https://$MISP_LAN_IP:$MISP_HTTPS_PORT for https://$MISP_HOSTNAME
  3. cd zsazsa/docker && docker compose build && docker compose up -d
  4. Log in at https://$MISP_HOSTNAME as $ADMIN_EMAIL, with ADMIN_PASSWORD from misp-docker/.env
EOF
