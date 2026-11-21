#!/usr/bin/env bash
# Collects the state of this deployment into one report, for checking or
# troubleshooting: containers, networks, configuration and recent log lines.
# Read-only. Passwords, keys and other long tokens are masked, but read the
# report before you share it: hostnames and addresses are left in.
#
#   bash scripts/report.sh [output file]     (default: /tmp/misp-zsazsa-report.txt)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-/tmp/misp-zsazsa-report.txt}"
LAN_NETWORK_NAME="$(grep -E '^LAN_NETWORK_NAME=' "$ROOT/misp-docker/.env" 2> /dev/null | cut -d= -f2)"

# Compose reads .env, and with it COMPOSE_FILE, from the current directory.
MISP() { (cd "$ROOT/misp-docker" && docker compose "$@"); }
ZSAZSA() { (cd "$ROOT/zsazsa/docker" && docker compose "$@"); }

section() { printf '\n===== %s =====\n' "$*"; }
cake() { MISP exec -T misp-core sudo -u www-data /var/www/MISP/app/Console/cake "$@" 2>&1; }

# Values of secret settings, then anything that still looks like a token.
mask() {
    sed -E \
        -e 's/([A-Za-z_.]*(PASSWORD|PASSPHRASE|SECRET|_KEY|APIKEY|TOKEN)[A-Za-z_]*["'"'"']?[[:space:]]*[=:][[:space:]]*["'"'"']?)[^"'"'"'[:space:],]+/\1***/Ig' \
        -e 's/(auth=)[^&"'"'"'[:space:]]+/\1***/g' \
        -e 's/[A-Za-z0-9]{32,}/***/g'
}

{
    section "Host"
    date -Is
    uname -a
    docker version --format 'Docker {{.Server.Version}}' 2>&1
    docker compose version 2>&1
    free -h
    df -h "$ROOT" /var/lib/docker 2> /dev/null
    docker stats --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}' 2>&1

    section "Containers"
    MISP ps -a 2>&1
    ZSAZSA ps -a 2>&1
    docker ps -a --filter name=misp-docker- --filter name=zsazsa- \
        --format '{{.Names}}' | xargs -r docker inspect -f '{{.Name}} restarts={{.RestartCount}} oomkilled={{.State.OOMKilled}} policy={{.HostConfig.RestartPolicy.Name}}' 2>&1

    section "Networks"
    docker network inspect "${LAN_NETWORK_NAME:-cti-lan}" -f 'driver={{.Driver}} options={{.Options}} ipam={{json .IPAM.Config}}' 2>&1
    docker network inspect misp-docker_default -f '{{range .Containers}}{{.Name}} {{.IPv4Address}}{{"\n"}}{{end}}' 2>&1
    docker inspect misp-docker-misp-nginx-1 -f '{{range $n, $c := .NetworkSettings.Networks}}{{$n}}={{$c.IPAddress}} {{end}}' 2>&1

    section "misp-docker/.env (non-empty, masked)"
    grep -vE '^[[:space:]]*(#|$)|=$' "$ROOT/misp-docker/.env" 2>&1

    section "zsazsa/docker/.env (masked)"
    grep -vE '^[[:space:]]*(#|$)' "$ROOT/zsazsa/docker/.env" 2>&1

    section "misp-nginx: listen, real IP and zsazsa locations"
    MISP exec -T misp-nginx nginx -T 2>&1 | grep -E 'listen|real_ip|set_real_ip_from|server_name|zsazsa|proxy_pass|test is|emerg'
    MISP logs --tail 30 misp-nginx 2>&1

    section "MISP settings"
    for s in MISP.baseurl MISP.external_baseurl MISP.live MISP.host_org_id MISP.email Security.rest_client_baseurl \
        Security.csp_enforce Security.require_password_confirmation Session.defaults Session.timeout \
        Session.cookieTimeout Session.autoRegenerate SimpleBackgroundJobs.enabled Plugin.Enrichment_services_url; do
        value="$(cake Admin getSetting "$s" | tr -d '\n' | grep -oE '"value": *("[^"]*"|[^,}]*)' | head -n 1)"
        printf '%s = %s\n' "$s" "${value#*: }"
    done
    # Sessions (single sign-on) belong in db0; MISP's jobs use db1, its cache db13.
    printf 'PHP sessions in Redis db0: %s\n' "$(MISP exec -T redis sh -c 'valkey-cli -a "$REDIS_PASSWORD" --no-auth-warning -n 0 --scan --pattern "PHPREDIS_SESSION:*" | wc -l' 2>&1)"
    MISP exec -T misp-core sh -c 'grep -hE "^session\.(save_handler|save_path|cookie_secure|cookie_samesite)" /etc/php/*/fpm/php.ini' 2>&1

    section "MISP workers (supervisor)"
    MISP exec -T misp-core supervisorctl -c /etc/supervisor/supervisord.conf status 2>&1 | head -40

    section "MISP log errors (last 40)"
    MISP logs --tail 500 misp-core 2>&1 | grep -iE 'error|fail|fatal|warn|denied' | tail -40
    for f in error.log exec-errors.log; do
        printf -- '--- misp-docker/logs/%s\n' "$f"
        tail -n 40 "$ROOT/misp-docker/logs/$f" 2>&1
    done

    section "Redis"
    MISP exec -T redis sh -c 'valkey-cli -a "$REDIS_PASSWORD" --no-auth-warning info keyspace; valkey-cli -a "$REDIS_PASSWORD" --no-auth-warning info memory | grep -E "used_memory_human|maxmemory_human"' 2>&1

    section "Database"
    MISP exec -T db sh -c 'mariadb -uroot -p"$MYSQL_ROOT_PASSWORD" -N -e "SELECT table_schema, ROUND(SUM(data_length+index_length)/1024/1024) AS mb FROM information_schema.tables GROUP BY table_schema; SELECT COUNT(*) AS events FROM $MYSQL_DATABASE.events; SELECT COUNT(*) AS users FROM $MYSQL_DATABASE.users;"' 2>&1

    section "zsazsa configuration (selected, masked)"
    grep -E '^(MISP_|LLM_|OPENAI_ENABLED|OPENAI_MODEL|LOCAL_LLM_(ENABLED|URL|MODEL)|SCRAPER_|JOB_REDIS_(HOST|PORT|DB)|LOG_LEVEL|THEME|ANALYSER_|POLL_WINDOW)' \
        "$ROOT/zsazsa/docker/volumes/config/__init__.py" 2>&1

    section "zsazsa reaches MISP through the reverse proxy"
    ZSAZSA exec -T webapp python -c "import config, urllib.request; r = urllib.request.urlopen(config.MISP_WEBAPP_URL + '/users/login', timeout=10); print(config.MISP_WEBAPP_URL, r.status)" 2>&1 | tail -3

    section "zsazsa and misp-scraper logs (last lines)"
    for s in webapp analyser imap-collector scraper-subscribe scraper-cron; do
        printf -- '--- %s\n' "$s"
        ZSAZSA logs --tail 15 "$s" 2>&1
    done
    printf -- '--- zsazsa/docker/volumes/data/analyser.log\n'
    tail -n 40 "$ROOT/zsazsa/docker/volumes/data/analyser.log" 2>&1
    printf -- '--- zsazsa/docker/volumes/scraper-config/scraper.log\n'
    tail -n 40 "$ROOT/zsazsa/docker/volumes/scraper-config/scraper.log" 2>&1
    grep -E '^(misp_url|misp_verifycert|misp_distribution|rawhtml_distribution|logging_level|misp_scraper_tags_local|redis_channel)' \
        "$ROOT/zsazsa/docker/volumes/scraper-config/scraper.py" 2>&1
} 2>&1 | grep -v 'variable is not set' | mask > "$OUT"

echo "Report written to $OUT ($(wc -l < "$OUT") lines). Check it before you share it."
