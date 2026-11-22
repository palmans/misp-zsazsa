# Shared by the scripts in this folder; sourced, not run.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETTINGS="$ROOT/deploy/settings.env"
MISP_DIR="$ROOT/misp-docker"
MISP_ENV="$MISP_DIR/.env"
ZSAZSA_DIR="$ROOT/zsazsa/docker"
ZSAZSA_ENV="$ZSAZSA_DIR/.env"
VOL="$ZSAZSA_DIR/volumes"
ZSAZSA_CFG="$VOL/config/__init__.py"
SCRAPER_CFG="$VOL/scraper-config/scraper.py"

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

# The zsazsa and misp-scraper containers run as uid 1000 and write their files.
own_volumes() {
    chmod 600 "$ZSAZSA_CFG" "$SCRAPER_CFG"
    if is_root; then
        chown -R 1000:1000 "$VOL"
    elif on_linux && [[ "$(id -u)" != 1000 ]]; then
        warn "Run as root, or chown -R 1000:1000 zsazsa/docker/volumes: the containers run as uid 1000."
    fi
}
