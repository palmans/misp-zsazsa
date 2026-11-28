#!/usr/bin/env bash
# End-to-end test: installs this deployment on this Docker host the way
# README.md describes, in a copy of the repository, and checks that it works
# the way it is used:
#
#   - scripts/init.sh, MISP (misp-docker), zsazsa and misp-scraper built and
#     started, scripts/post-install.sh
#   - a reverse proxy made from deploy/reverse-proxy.example.conf, in front of
#     misp-nginx on a stand-in for the LAN network
#   - MISP through the proxy and on its LAN address, /zsazsa/, the way back to
#     zsazsa after a MISP login, single sign-on
#   - zsazsa and misp-scraper calling MISP with their own API keys (limited to
#     the addresses they call from), misp-scraper listening on Redis
#   - what customize_misp.sh and init.sh set inside the containers
#   - scripts/sync-prompts.sh, scripts/report.sh, post-install.sh run again,
#     the database backup of README.md
#
# With --upgrade-from REF it first installs REF (e.g. main), checks it, makes
# a MISP event, then updates to the commit under test as README.md's
# "Updating" says (git checkout instead of git pull) and checks it all again.
#
#   sudo bash tests/e2e.sh [--upgrade-from REF] [--keep] [--no-pull]
#
#   --keep     leave the stacks running (and the copy in place) afterwards
#   --no-pull  use the images on this host: no "docker compose pull", and the
#              zsazsa images are built without --pull (for a host that cannot
#              reach the registries; the README steps do pull)
#
# Tests the commit checked out here, with uncommitted changes to tracked files.
# Needs root (as on the Docker host: the scripts give the volumes to uid 1000),
# Docker with Compose, python3, openssl, iptables, about 6 GB of memory and
# 20-40 minutes. On failure the logs and report.sh's report go to
# $E2E_LOGS (default: e2e-logs/ in this repository).
#
# Uses the names of a real deployment (Compose projects misp-docker and zsazsa,
# network cti-lan) and refuses to run where they exist: never on the Docker
# host of the deployment itself.
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

UPGRADE_FROM=""
KEEP=0
PULL=1
while (( $# )); do
    case "$1" in
        --upgrade-from) UPGRADE_FROM=${2:?--upgrade-from needs a git ref}; shift ;;
        --keep) KEEP=1 ;;
        --no-pull) PULL=0 ;;
        *) echo "Usage: sudo bash tests/e2e.sh [--upgrade-from REF] [--keep] [--no-pull]" >&2; exit 2 ;;
    esac
    shift
done

die() {
    fail "$*"
    exit 1
}
step() {
    SECTION="$*"
    printf '\n%s[%s] %s%s\n' "$B" "$(date +%T)" "$*" "$OFF"
}
g() { git -c safe.directory='*' -C "$REPO" "$@"; }
sgit() { git -c safe.directory='*' -C "$SANDBOX" "$@"; }
E2E_BRANCH=misp-zsazsa-e2e

# --- Test values ---------------------------------------------------------------

NET=${E2E_NET:-10.231.19}                 # the stand-in LAN, a /24
LAN_BRIDGE=e2e-lan0                       # its interface on this host
HOSTNAME_=misp.example.test
ADMIN_EMAIL=admin@example.com
LAN_IP=$NET.19
PROXY_IP=$NET.105
HTTPS_PORT=8443
HTTP_PORT=8080
PROXY_IMAGE=nginx:1.29-alpine
PROXY_NAME=misp-zsazsa-e2e-proxy
LOGS=${E2E_LOGS:-$REPO/e2e-logs}
SANDBOX=""   # the copy of the repository (a git worktree)
WORK=""      # files of the test itself
IPTABLES_RULES=()

# --- Clean up ------------------------------------------------------------------

collect_logs() {
    [[ -n "$SANDBOX" && -d "$SANDBOX" ]] || return 0
    mkdir -p "$LOGS"
    info "logs and report.sh's report in $LOGS"
    local stack
    for stack in misp-docker zsazsa/docker; do
        (cd "$SANDBOX/$stack" && docker compose ps -a && docker compose logs --no-color --timestamps --tail 1000) \
            > "$LOGS/${stack%%/*}.log" 2>&1
    done
    docker logs "$PROXY_NAME" > "$LOGS/reverse-proxy.log" 2>&1
    bash "$SANDBOX/scripts/report.sh" "$LOGS/report.txt" > /dev/null 2>&1
    chmod -R a+rX "$LOGS"
}

cleanup() {
    local status=$?
    trap - EXIT INT TERM
    if (( FAILED || status )); then
        collect_logs
    fi
    if (( KEEP )); then
        info "--keep: left running; the copy is in $SANDBOX"
    else
        step "Clean up"
        if [[ -n "$SANDBOX" && -d "$SANDBOX" ]]; then
            (cd "$SANDBOX/zsazsa/docker" && docker compose down -v --remove-orphans) > /dev/null 2>&1
            (cd "$SANDBOX/misp-docker" && docker compose down -v --remove-orphans) > /dev/null 2>&1
        fi
        docker rm -f "$PROXY_NAME" > /dev/null 2>&1
        docker network rm cti-lan > /dev/null 2>&1
        local rule
        for rule in "${IPTABLES_RULES[@]}"; do
            # shellcheck disable=SC2086
            iptables -D DOCKER-USER $rule 2> /dev/null
        done
        if [[ -n "$SANDBOX" ]]; then
            g worktree remove --force "$SANDBOX" > /dev/null 2>&1
            g worktree prune
            g branch -q -D "$E2E_BRANCH-deployed" "$E2E_BRANCH-target" > /dev/null 2>&1
        fi
        [[ -n "$WORK" ]] && rm -rf "$WORK"
    fi
    finish "tests/e2e.sh${UPGRADE_FROM:+ (upgrade from $UPGRADE_FROM)}"
    local finished=$?
    exit $(( status ? status : finished ))
}

# --- Preflight -----------------------------------------------------------------

section "Preflight"
[[ "$(id -u)" == 0 ]] || { echo "Run as root: sudo bash tests/e2e.sh" >&2; exit 2; }
command -v docker > /dev/null && docker info > /dev/null 2>&1 || { echo "Docker is not running." >&2; exit 2; }
for tool in python3 openssl iptables git; do
    command -v "$tool" > /dev/null || { echo "$tool is required." >&2; exit 2; }
done
info "$(docker version --format 'Docker {{.Server.Version}}'), $(docker compose version)"
for project in misp-docker zsazsa; do
    if [[ -n "$(docker ps -aq --filter "label=com.docker.compose.project=$project")" ]]; then
        echo "Compose project $project exists on this host: not on the host of a deployment." >&2
        exit 2
    fi
done
for network in cti-lan misp-docker_default; do
    if docker network inspect "$network" > /dev/null 2>&1; then
        echo "Network $network exists on this host: not on the host of a deployment." >&2
        exit 2
    fi
done

# The commit under test, with uncommitted changes to tracked files.
TARGET=$(g stash create 2> /dev/null)
TARGET=${TARGET:-$(g rev-parse HEAD)}
FIRST=${UPGRADE_FROM:-$TARGET}
if [[ -n "$UPGRADE_FROM" ]]; then
    g rev-parse --verify -q "$UPGRADE_FROM^{commit}" > /dev/null || { echo "Unknown git ref $UPGRADE_FROM (fetched?)." >&2; exit 2; }
fi

trap cleanup EXIT
trap 'exit 130' INT TERM

# --- Install ---------------------------------------------------------------------

WORK=$(mktemp -d /tmp/misp-zsazsa-e2e.XXXXXX)
SANDBOX="$WORK/repo"
step "Copy of $(g rev-parse --short "$FIRST") in $SANDBOX"
g worktree add -q --detach "$SANDBOX" "$FIRST" || die "git worktree add"

MENV="$SANDBOX/misp-docker/.env"
ZCFG="$SANDBOX/zsazsa/docker/volumes/config/__init__.py"
SCFG="$SANDBOX/zsazsa/docker/volumes/scraper-config/scraper.py"
misp() { (cd "$SANDBOX/misp-docker" && docker compose "$@"); }
zsazsa() { (cd "$SANDBOX/zsazsa/docker" && docker compose "$@"); }
cake() { misp exec -T misp-core sudo -u www-data /var/www/MISP/app/Console/cake "$@"; }

# Steps 2 and 3 of README.md's installation.
settings() {
    cat > "$SANDBOX/deploy/settings.env" << EOF
MISP_HOSTNAME=$HOSTNAME_
ADMIN_EMAIL=$ADMIN_EMAIL
ADMIN_ORG=E2E Test Org
TZ=Europe/Amsterdam
MISP_LAN_IP=$LAN_IP
MISP_HTTPS_PORT=$HTTPS_PORT
MISP_HTTP_PORT=$HTTP_PORT
LAN_NETWORK_NAME=cti-lan
LAN_DRIVER=ipvlan
LAN_PARENT=$LAN_BRIDGE
LAN_SUBNET=$NET.0/24
LAN_GATEWAY=$NET.1
LAN_IP_RANGE=$NET.16/29
PROXY_IP=$PROXY_IP
PROXY_CERT_VALID=false
EOF
}

# The LAN: a bridge instead of ipvlan, which the host itself cannot reach. The
# reverse proxy is on it, as on a real LAN; this host is its gateway, and
# containers on misp-docker's network reach it NATed from that address, as
# they reach a real proxy from the host's LAN address (post-install.sh limits
# zsazsa's key to that address).
lan_network() {
    # nat-unprotected: Docker (28 and later) would drop packets from other
    # networks to the containers on it, the reverse proxy among them.
    docker network create -d bridge --subnet "$NET.0/24" --gateway "$NET.1" --ip-range "$NET.16/29" \
        -o com.docker.network.bridge.name="$LAN_BRIDGE" -o com.docker.network.bridge.gateway_mode_ipv4=nat-unprotected \
        cti-lan > /dev/null || die "creating the LAN network"
    # Docker isolates its networks from each other; a real LAN is not.
    local rule
    for rule in "-s $NET.0/24 -j ACCEPT" "-d $NET.0/24 -j ACCEPT"; do
        # shellcheck disable=SC2086
        iptables -I DOCKER-USER $rule && IPTABLES_RULES+=("$rule")
    done
}

reverse_proxy() {
    local dir="$WORK/proxy" conf
    mkdir -p "$dir/certs"
    conf=$(sed -e "s/misp\.example\.com/$HOSTNAME_/g" -e "s/192\.168\.1\.19:8443/$LAN_IP:$HTTPS_PORT/g" \
        "$SANDBOX/deploy/reverse-proxy.example.conf")
    if grep -vE '^[[:space:]]*#' <<< "$conf" | grep -qE 'example\.com|192\.168\.'; then
        fail "deploy/reverse-proxy.example.conf has values this test does not know" \
            "$(grep -vE '^[[:space:]]*#' <<< "$conf" | grep -E 'example\.com|192\.168\.')"
    fi
    printf '%s\n' "$conf" > "$dir/default.conf"
    openssl req -x509 -nodes -newkey rsa:2048 -days 2 -subj "/CN=$HOSTNAME_" \
        -keyout "$dir/certs/privkey.pem" -out "$dir/certs/fullchain.pem" 2> /dev/null
    chmod 644 "$dir/certs/privkey.pem"
    docker run -d --name "$PROXY_NAME" --restart unless-stopped --network cti-lan --ip "$PROXY_IP" \
        -v "$dir/default.conf:/etc/nginx/conf.d/default.conf:ro" -v "$dir/certs:/etc/ssl/$HOSTNAME_:ro" \
        "$PROXY_IMAGE" > /dev/null || die "starting the reverse proxy"
    sleep 2
    check "reverse proxy from deploy/reverse-proxy.example.conf runs" \
        docker exec "$PROXY_NAME" nginx -t
}

# README.md, installation steps 4 and 6, and the update steps.
start_stacks() {
    local build=(build)
    (( PULL )) && build+=(--pull)
    if (( PULL )); then
        check "misp-docker: docker compose pull" misp pull -q
    fi
    # The first start of MISP (database, galaxies, warninglists) takes minutes.
    check "misp-docker: docker compose up -d (until healthy)" misp up -d --wait --wait-timeout 1200
    check "zsazsa: docker compose ${build[*]}" zsazsa "${build[@]}"
    check "zsazsa: docker compose up -d (until running and healthy)" zsazsa up -d --wait --wait-timeout 600
}

step "Settings, LAN network, scripts/init.sh"
settings
lan_network
check "init.sh" bash "$SANDBOX/scripts/init.sh"
[[ -s "$MENV" ]] || die "init.sh wrote no misp-docker/.env"
# PHP-FPM and nginx in misp-docker listen on IPv6 too, unless told otherwise:
# on a host without IPv6 they would not start.
if [[ ! -e /proc/net/if_inet6 ]]; then
    info "this host has no IPv6: DISABLE_IPV6=true in misp-docker/.env, as a deployment here would need"
    sed -i '/^DISABLE_IPV6=/d' "$MENV" && echo DISABLE_IPV6=true >> "$MENV"
fi
ADMIN_KEY=$(env_value "$MENV" ADMIN_KEY)
ADMIN_PASSWORD=$(env_value "$MENV" ADMIN_PASSWORD)
expect_eq "zsazsa/docker/volumes belongs to uid 1000" 1000 "$(stat -c %u "$SANDBOX/zsazsa/docker/volumes/config")"

step "Reverse proxy"
reverse_proxy

step "Start MISP and zsazsa"
start_stacks
[[ "$(misp ps -q misp-nginx)" ]] || die "misp-nginx did not start"

step "scripts/post-install.sh"
if out=$(bash "$SANDBOX/scripts/post-install.sh" 2>&1); then
    pass "post-install.sh"
else
    fail "post-install.sh" "$(tail -n 30 <<< "$out")"
fi
printf '%s\n' "$out" | sed 's/^/       /'
# It restarted zsazsa and misp-scraper.
check "zsazsa: running and healthy again" zsazsa up -d --wait --wait-timeout 300

# --- Checks ------------------------------------------------------------------------

# Prints the value of a MISP setting (cake Admin getSetting).
misp_setting() {
    cake Admin getSetting "$1" 2>&1 | python3 -c 'import json, sys; print(json.dumps(json.load(sys.stdin).get("value")))' 2>&1
}

verify() {
    local phase=$1 out

    section "$phase: containers"
    local stack svc state restarts
    for stack in misp zsazsa; do
        while read -r svc; do
            [[ -n "$svc" ]] || continue
            state=$($stack ps --format '{{.State}} {{.Health}}' "$svc" 2>&1 | sed 's/ *$//')
            expect_match "$svc runs${state:+ ($state)}" '^running( healthy)?$' "$state"
        done < <($stack config --services)
    done
    # Crash loops: a container that restarted is not fine because it runs now.
    for id in $(misp ps -q) $(zsazsa ps -q); do
        restarts=$(docker inspect -f '{{.Name}} {{.RestartCount}}' "$id")
        expect_match "${restarts% *} did not restart" ' 0$' "$restarts"
    done

    section "$phase: inside MISP (customize_misp.sh, init.sh)"
    expect_eq "Security.force_https" true "$(misp_setting Security.force_https)"
    expect_eq "GnuPG.sign" true "$(misp_setting GnuPG.sign)"
    expect_eq "MISP.default_event_distribution" '"0"' "$(misp_setting MISP.default_event_distribution | sed 's/^0$/"0"/')"
    expect_eq "MISP.baseurl" "\"https://$HOSTNAME_\"" "$(misp_setting MISP.baseurl)"
    out=$(misp exec -T misp-core sh -c 'grep -hE "^session\.(use_strict_mode|sid_bits_per_character)" /etc/php/*/fpm/php.ini' 2>&1)
    expect_match "PHP session hardening in php.ini" $'session.use_strict_mode = 1\nsession.sid_bits_per_character = 5' "$out"
    out=$(misp logs misp-core 2>&1 | grep -c 'customize_misp.sh |')
    expect_match "customize_misp.sh ran at the start of misp-core" '^[1-9]' "$out"
    # The mail image appends the mounted file to exim's local macros at its start.
    check "exim in the mail container reads misp-docker/exim-macros of init.sh" \
        misp exec -T mail grep -q 'Written by scripts/init.sh' /etc/exim4/exim4.conf.localmacros
    out=$(misp exec -T misp-nginx nginx -T 2>&1)
    expect_match "misp-nginx has the /zsazsa/ locations of 05-zsazsa.sh" 'location \^~ /zsazsa/' "$out"
    expect_match "misp-nginx trusts X-Forwarded-For of the reverse proxy" "set_real_ip_from $PROXY_IP" "$out"
    expect_match "misp-nginx listens on MISP_HTTPS_PORT" "listen $HTTPS_PORT ssl" "$out"

    section "$phase: through the reverse proxy, as a browser"
    py_checks "$TESTS/e2e_http.py" "$HOSTNAME_" "$PROXY_IP" "$LAN_IP" "$HTTPS_PORT" "$HTTP_PORT" \
        "$ADMIN_EMAIL" "$ADMIN_PASSWORD" "$ADMIN_KEY" "$(env_value "$MENV" CORE_RUNNING_TAG)"

    section "$phase: zsazsa and misp-scraper use MISP"
    local zkey skey
    zkey=$(py_value "$ZCFG" MISP_KEY)
    skey=$(py_value "$SCFG" misp_key)
    if [[ "$zkey" != *"$ADMIN_KEY"* && "$skey" != *"$ADMIN_KEY"* ]]; then
        pass "post-install.sh replaced the administrator's key in both configurations"
    else
        fail "post-install.sh replaced the administrator's key in both configurations"
    fi
    expect_match "zsazsa: MISP_SESSION_COOKIE_NAME set by post-install.sh" "^'MISP-[0-9a-f-]{36}'$" "$(py_value "$ZCFG" MISP_SESSION_COOKIE_NAME)"
    # Through the reverse proxy, with the key limited to the host's address.
    out=$(zsazsa exec -T webapp python - 2>&1 << 'PY'
import config
from pymisp import PyMISP
misp = PyMISP(config.MISP_URL, config.MISP_KEY, config.MISP_VERIFYCERT, timeout=60)
user, role, _ = misp.get_user("me", pythonify=True, expanded=True)
print(f"{user.email} {role.name}")
PY
    )
    expect_match "zsazsa calls MISP's API through the proxy with its own key (role zsazsa)" \
        "${ADMIN_EMAIL%@*}\+zsazsa@${ADMIN_EMAIL#*@} zsazsa$" "$out"
    out=$(zsazsa run --rm --no-deps -T --entrypoint python scraper-cron - 2>&1 << 'PY'
import scraper
from pymisp import PyMISP
misp = PyMISP(scraper.misp_url, scraper.misp_key, scraper.misp_verifycert, timeout=60)
print(misp.get_user("me", pythonify=True).email)
PY
    )
    expect_match "misp-scraper calls misp-nginx with its own key" "${ADMIN_EMAIL%@*}\+scraper@${ADMIN_EMAIL#*@}$" "$out"
    out=$(misp exec -T redis sh -c 'valkey-cli -a "$REDIS_PASSWORD" --no-auth-warning PUBSUB NUMSUB urls' 2>&1)
    expect_match "scraper-subscribe listens for zsazsa's URLs on Redis" $'^urls\n[1-9]' "$out"

    section "$phase: scripts"
    local before after
    before=$(sha256sum "$ZCFG" "$SCFG")
    if out=$(bash "$SANDBOX/scripts/post-install.sh" 2>&1) && [[ "$out" == *exists* && "$out" != *"API key added"* ]]; then
        pass "post-install.sh again leaves the users and keys alone"
    else
        fail "post-install.sh again leaves the users and keys alone" "$(tail -n 20 <<< "$out")"
    fi
    after=$(sha256sum "$ZCFG" "$SCFG")
    expect_eq "post-install.sh again changes no configuration" "$before" "$after"
    out=$(bash "$SANDBOX/scripts/sync-prompts.sh" 2>&1)
    expect_match "sync-prompts.sh: the prompts match the image" 'All prompts match' "$out"
    if out=$(bash "$SANDBOX/scripts/report.sh" "$WORK/report.txt" 2>&1); then
        pass "report.sh"
        local secret leaked=()
        for secret in "$ADMIN_KEY" "$ADMIN_PASSWORD" "$(env_value "$MENV" REDIS_PASSWORD)" \
            "$(env_value "$MENV" MYSQL_ROOT_PASSWORD)" "$(py_value "$ZCFG" MISP_KEY | tr -d "'")" \
            "$(py_value "$ZCFG" SECRET_KEY | tr -d "'")"; do
            grep -qF "$secret" "$WORK/report.txt" && leaked+=("${secret:0:4}...")
        done
        expect_eq "report.sh masks passwords and keys" "" "${leaked[*]}"
        expect_match "report.sh: zsazsa reaches MISP through the proxy" "https://$HOSTNAME_ 200" \
            "$(grep -A 3 'zsazsa reaches MISP' "$WORK/report.txt")"
    else
        fail "report.sh" "$(tail -n 20 <<< "$out")"
    fi
    # README.md, "Backup and restore".
    if misp exec -T db sh -c 'exec mariadb-dump --single-transaction -uroot -p"$MYSQL_ROOT_PASSWORD" "$MYSQL_DATABASE"' |
        gzip > "$WORK/misp-db.sql.gz" && grep -q 'CREATE TABLE `users`' <(zcat "$WORK/misp-db.sql.gz"); then
        pass "database backup of README.md"
    else
        fail "database backup of README.md"
    fi

    # What init.sh, the scripts and the containers write must leave the files
    # git tracks alone (or the next "git pull" fails), and be in .gitignore
    # (or it shows up to be committed, secrets included).
    section "$phase: the checkout"
    out=$(sgit status --porcelain --untracked-files=no 2>&1)
    expect_eq "no file git tracks changed (git pull keeps working)" "" "$out"
    out=$(sgit status --porcelain --untracked-files=all 2>&1 | grep '^??')
    expect_eq "every file the deployment wrote is in .gitignore" "" "$out"
}

misp_api() {
    curl -sk --noproxy '*' --resolve "$HOSTNAME_:443:$PROXY_IP" -H "Authorization: $ADMIN_KEY" -H 'Accept: application/json' \
        -H 'Content-Type: application/json' "https://$HOSTNAME_$1" "${@:2}"
}

if [[ -n "$UPGRADE_FROM" ]]; then
    verify "$(g rev-parse --short "$UPGRADE_FROM") (before the update)"

    step "Update to $(g rev-parse --short "$TARGET")"
    EVENT=$(misp_api /events/add -d '{"Event": {"info": "e2e: made before the update", "distribution": 0}}' |
        python3 -c 'import json, sys; print(json.load(sys.stdin)["Event"]["id"])' 2>&1)
    expect_match "MISP event made before the update" '^[0-9]+$' "$EVENT"
    # README.md, "Updating": scripts/update.sh. Its git pull comes from a branch
    # at the commit under test, which the deployed copy follows.
    update=(--yes)
    (( PULL )) || update+=(--no-image-pull)
    if g merge-base --is-ancestor "$FIRST" "$TARGET"; then
        g branch -f "$E2E_BRANCH-target" "$TARGET" > /dev/null &&
            sgit checkout -q -b "$E2E_BRANCH-deployed" &&
            sgit branch -q --set-upstream-to="$E2E_BRANCH-target" || die "git branches for the update"
        if [[ ! -f "$SANDBOX/scripts/update.sh" ]]; then
            # A version without update.sh: git pull by hand, then the new update.sh.
            info "$(g rev-parse --short "$FIRST") has no scripts/update.sh: git pull, then update.sh --skip-git"
            sgit merge -q --ff-only "$E2E_BRANCH-target" || die "git pull"
            update+=(--skip-git)
        fi
    else
        info "$(g rev-parse --short "$TARGET") does not fast-forward from $(g rev-parse --short "$FIRST"): git checkout, then update.sh --skip-git"
        sgit checkout -q --detach "$TARGET" || die "git checkout $TARGET"
        update+=(--skip-git)
    fi
    if out=$(bash "$SANDBOX/scripts/update.sh" "${update[@]}" 2>&1); then
        pass "scripts/update.sh ${update[*]}"
    else
        fail "scripts/update.sh ${update[*]}" "$(tail -n 40 <<< "$out")"
    fi
    # Without the progress of docker compose.
    printf '%s\n' "$out" | grep -vE '^( *(Container|Image|Network|Volume) |#[0-9]+ |$)' | sed 's/^/       /'
    expect_eq "update.sh brought the checkout to the commit under test" "$(g rev-parse "$TARGET")" "$(sgit rev-parse HEAD)"
    verify "$(g rev-parse --short "$TARGET") (after the update)"
    section "after the update: data"
    out=$(misp_api "/events/view/$EVENT" | python3 -c 'import json, sys; print(json.load(sys.stdin)["Event"]["info"])' 2>&1)
    expect_eq "MISP event made before the update is still there" "e2e: made before the update" "$out"
else
    verify "$(g rev-parse --short "$TARGET")"
fi
