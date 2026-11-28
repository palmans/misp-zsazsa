#!/usr/bin/env bash
# Checks that this deployment (deploy/, scripts/) still fits the upstream
# folders misp-docker/, misp-scraper/ and zsazsa/, without starting anything:
#
#   - our scripts: syntax, ShellCheck, file modes
#   - the patches of deploy/patches/ are in the upstream folders
#   - what deploy/ and scripts/ rely on in upstream: file names, settings,
#     services, mount points, entrypoints
#   - scripts/lib.sh, scripts/init.sh (run twice in a copy of the repository)
#     and the Compose configuration of both stacks that comes out of it
#   - .github/scripts/upstream-pr.sh and scripts/update-upstream.sh
#   - the MISP images template.env pins exist
#
# Needs bash, git, python3, openssl and the docker CLI with Compose (no Docker
# daemon). ShellCheck when installed (required on GitHub). CHECK_OFFLINE=1
# skips the checks that need the internet. Takes a minute or two.
#
#   bash tests/check.sh
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cd "$REPO" || exit 1

# --- Our scripts ---------------------------------------------------------------

section "Scripts: syntax, ShellCheck and file modes"

BASH_SCRIPTS=(scripts/*.sh .github/scripts/*.sh tests/*.sh deploy/misp/customize_misp.sh)
for f in "${BASH_SCRIPTS[@]}"; do
    check "bash -n $f" bash -n "$f"
done
# Runs in misp-nginx, whose /bin/sh is dash: POSIX sh only.
if command -v dash > /dev/null; then
    check "dash -n deploy/nginx/05-zsazsa.sh (POSIX sh)" dash -n deploy/nginx/05-zsazsa.sh
else
    check "sh -n deploy/nginx/05-zsazsa.sh" sh -n deploy/nginx/05-zsazsa.sh
fi
check "python3 compiles deploy/misp/post_install.py" \
    python3 -c 'import ast, sys; ast.parse(open(sys.argv[1]).read(), sys.argv[1])' deploy/misp/post_install.py

if command -v shellcheck > /dev/null; then
    check "shellcheck (warnings and errors)" shellcheck -S warning "${BASH_SCRIPTS[@]}" deploy/nginx/05-zsazsa.sh
elif [[ -n "${CI:-}" ]]; then
    fail "shellcheck is not installed"
else
    skip "shellcheck is not installed"
fi

if command -v actionlint > /dev/null; then
    check "actionlint .github/workflows/" actionlint .github/workflows/*.yml
else
    skip "actionlint is not installed (.github/workflows/ not checked)"
fi

# misp-core runs customize_misp.sh only when it is executable, and nginx's
# entrypoint skips scripts in /docker-entrypoint.d that are not: both are
# mounted from this checkout, so git has to keep the bit.
for f in deploy/misp/customize_misp.sh deploy/nginx/05-zsazsa.sh scripts/init.sh scripts/post-install.sh \
    scripts/report.sh scripts/sync-prompts.sh scripts/update-upstream.sh .github/scripts/upstream-pr.sh; do
    mode=$(git -c safe.directory='*' ls-files -s -- "$f" | awk '{ print $1 }')
    expect_eq "$f is executable in git" 100755 "${mode:-<not in git>}"
done

# --- Patches ---------------------------------------------------------------------

section "Patches of deploy/patches/ are in the upstream folders"

shopt -s nullglob
patches=(deploy/patches/*/*.patch)
shopt -u nullglob
if (( ${#patches[@]} == 0 )); then
    skip "no patches"
fi
for patch in "${patches[@]}"; do
    dir=$(basename "$(dirname "$patch")")
    # Applied when it can be reversed cleanly.
    if out=$(git apply --check --reverse --directory="$dir" "$patch" 2>&1); then
        pass "$patch is applied to $dir/"
    elif git apply --check --directory="$dir" "$patch" > /dev/null 2>&1; then
        fail "$patch is NOT applied to $dir/ (it would apply: run scripts/update-upstream.sh, or apply it)"
    else
        fail "$patch no longer fits $dir/: upstream changed that code, or fixed it; update or remove the patch" "$out"
    fi
done

# --- Upstream: what deploy/ and scripts/ rely on ------------------------------------

section "Upstream misp-docker: what deploy/ and scripts/ rely on"

for tag in CORE_TAG MODULES_TAG GUARD_TAG; do
    value=$(env_value misp-docker/template.env "$tag")
    expect_match "template.env sets $tag (init.sh pins the images to it)" '^v?[0-9]' "$value"
done

nginx_dockerfile=misp-docker/nginx/Dockerfile
for var in NGINX_INCLUDE_DIR NGINX_INTERNAL_HTTP_PORT NGINX_INTERNAL_HTTPS_PORT; do
    check "misp-nginx image sets $var (misp-docker.override.yml / 05-zsazsa.sh use it)" \
        grep -qE "^ENV $var=" "$nginx_dockerfile"
done
check "misp-nginx listens on NGINX_INTERNAL_HTTPS_PORT (01-listen.sh)" \
    grep -q 'NGINX_INTERNAL_HTTPS_PORT' misp-docker/nginx/files/01-listen.sh
check "03-conditional-headers.sh (re)creates conditional-headers.conf, to which 05-zsazsa.sh appends" \
    grep -q 'conditional-headers.conf' misp-docker/nginx/files/03-conditional-headers.sh
check "misp-nginx copies 03-conditional-headers.sh into /docker-entrypoint.d/" \
    grep -qE 'COPY .*03-conditional-headers.sh /docker-entrypoint.d/' "$nginx_dockerfile"
# 05-zsazsa.sh adds "location" blocks: the file has to be included inside
# MISP's server block, and nothing may run after 05-zsazsa.sh and empty it.
py_checks - misp-docker/nginx/files/misp.conf misp-docker/nginx/files << 'PY'
import re, sys, os
conf = open(sys.argv[1]).read()
depth, inside = 0, None
for line in conf.splitlines():
    code = line.split("#", 1)[0]
    if "conditional-headers.conf" in code:
        inside = depth > 0 and inside is not False
    depth += code.count("{") - code.count("}")
if inside:
    print("PASS\tmisp.conf includes conditional-headers.conf inside a server block")
else:
    print("FAIL\tmisp.conf includes conditional-headers.conf inside a server block\tnot found, or at the top level")
late = [f for f in sorted(os.listdir(sys.argv[2]))
        if re.match(r"^(0[5-9]|[1-9][0-9])", f)
        and "conditional-headers" in open(os.path.join(sys.argv[2], f)).read()]
if late:
    print(f"FAIL\tno misp-nginx entrypoint script after 05-zsazsa.sh touches conditional-headers.conf\t{', '.join(late)}")
else:
    print("PASS\tno misp-nginx entrypoint script after 05-zsazsa.sh touches conditional-headers.conf")
PY
check "misp-core runs /custom/files/customize_misp.sh at its start" \
    grep -q '/custom/files/customize_misp.sh' misp-docker/core/files/entrypoint_fpm.sh
check "misp-core sets the admin password from ADMIN_PASSWORD (README: log in with it)" \
    grep -q 'ADMIN_PASSWORD' misp-docker/core/files/configure_misp.sh

section "Upstream zsazsa and misp-scraper: what deploy/ and scripts/ rely on"

for f in zsazsa/config/__init__.py.example zsazsa/docker/env.example zsazsa/docker/scraper.py.zsazsa \
    zsazsa/docker/docker-compose.yml zsazsa/docker/docker-compose.misp-docker.yml zsazsa/docker/Dockerfile \
    misp-scraper/feedlist.json misp-scraper/docker/Dockerfile misp-scraper/docker/entrypoint.sh; do
    check "$f exists" test -f "$f"
done
check "post-install.sh finds MISP_SESSION_COOKIE_NAME = '' in zsazsa's config" \
    grep -qE "^MISP_SESSION_COOKIE_NAME = ''$" zsazsa/config/__init__.py.example
check "misp-scraper/feedlist.json is valid JSON (init.sh copies it)" \
    python3 -c 'import json, sys; json.load(open(sys.argv[1]))' misp-scraper/feedlist.json
# own_volumes (lib.sh) gives the volumes to uid 1000.
check "the zsazsa image runs as uid 1000" grep -qE 'useradd .*--uid 1000' zsazsa/docker/Dockerfile
check "the misp-scraper image runs as uid 1000" grep -qE '^ARG UID=1000' misp-scraper/docker/Dockerfile
# sync-prompts.sh compares /opt/zsazsa/zsazsaprompts with /app/zsazsaprompts.
check "the zsazsa image keeps the shipped prompts in /opt/zsazsa (sync-prompts.sh)" \
    grep -qE 'cp -a .*zsazsaprompts.* /opt/zsazsa/' zsazsa/docker/Dockerfile
for cmd in subscribe cron-loop; do
    check "misp-scraper's entrypoint knows '$cmd' (zsazsa's compose file runs it)" \
        grep -qE "(^|[|[:space:]])${cmd}[|)]" misp-scraper/docker/entrypoint.sh
done

# --- scripts/lib.sh ----------------------------------------------------------------

section "scripts/lib.sh helpers"

(
    # shellcheck source=../scripts/lib.sh
    . scripts/lib.sh
    f="$TMP/lib.env"
    printf '%s\n' 'A=1' '# B=old' 'C="with space"' 'A=2' > "$f"
    [[ "$(get_env "$f" A)" == 2 ]] || { echo "get_env takes the last line: got $(get_env "$f" A)"; exit 1; }
    [[ "$(get_env "$f" C)" == "with space" ]] || { echo "get_env strips quotes"; exit 1; }
    [[ -z "$(get_env "$f" B)" && -z "$(get_env "$f" MISSING)" ]] || { echo "get_env of commented/missing"; exit 1; }
    set_env "$f" B new
    set_env "$f" D "two words"
    set_env "$f" A 3
    expected=$'A=3\nB=new\nC="with space"\nA=2\nD="two words"'
    [[ "$(cat "$f")" == "$expected" ]] || { echo "set_env result:"; cat "$f"; exit 1; }
) > "$TMP/out" 2>&1 && pass "get_env / set_env" || fail "get_env / set_env" "$(cat "$TMP/out")"

(
    # shellcheck source=../scripts/lib.sh
    . scripts/lib.sh
    f="$TMP/lib.py"
    printf '%s\n' "KEY = 'old'" "KEY_LONGER = 1" "OTHER = 2" > "$f"
    set_py "$f" KEY "'new'"
    set_py "$f" ADDED True
    expected=$'KEY = \'new\'\nKEY_LONGER = 1\nOTHER = 2\nADDED = True'
    [[ "$(cat "$f")" == "$expected" ]] || { echo "set_py result:"; cat "$f"; exit 1; }
    r=$(rand 40)
    [[ "$r" =~ ^[A-Za-z0-9]{40}$ ]] || { echo "rand 40: $r"; exit 1; }
) > "$TMP/out" 2>&1 && pass "set_py / rand" || fail "set_py / rand" "$(cat "$TMP/out")"

# --- scripts/init.sh in a copy ----------------------------------------------------

section "scripts/init.sh (in a copy of the repository, run twice)"

SANDBOX="$TMP/repo"
copy_repo "$SANDBOX"
HOSTNAME_=misp.test.example
ADMIN_EMAIL=admin@test.example
LAN_IP=10.231.19.19
PROXY_IP=10.231.19.105
# CRLF line endings, quotes and a value with spaces, as an editor on Windows
# may leave them.
printf '%s\r\n' \
    "# test settings" \
    "MISP_HOSTNAME=$HOSTNAME_" \
    "ADMIN_EMAIL=$ADMIN_EMAIL" \
    'ADMIN_ORG="Test Org"' \
    "TZ=Europe/Amsterdam" \
    "" \
    "MISP_LAN_IP=$LAN_IP" \
    "MISP_HTTPS_PORT=8443" \
    "MISP_HTTP_PORT=8080" \
    "LAN_NETWORK_NAME=cti-lan" \
    "LAN_DRIVER=ipvlan" \
    "LAN_PARENT=eth0" \
    "LAN_SUBNET=10.231.19.0/24" \
    "LAN_GATEWAY=10.231.19.1" \
    "LAN_IP_RANGE=10.231.19.16/29" \
    "PROXY_IP=$PROXY_IP" \
    "PROXY_CERT_VALID=false" > "$SANDBOX/deploy/settings.env"

# A docker that records the network commands of init.sh and passes everything
# else (compose) to the real one.
mkdir -p "$TMP/bin"
REAL_DOCKER=$(command -v docker || true)
cat > "$TMP/bin/docker" << EOF
#!/usr/bin/env bash
if [[ "\$1" == network ]]; then
    echo "docker \$*" >> "$TMP/docker-network.log"
    [[ "\$2" == inspect ]] && exit 1
    exit 0
fi
exec "${REAL_DOCKER:-false}" "\$@"
EOF
chmod +x "$TMP/bin/docker"
SPATH="$TMP/bin:$PATH"

# Every file init.sh writes.
GENERATED=(misp-docker/.env misp-docker/ssl/cert.pem misp-docker/ssl/key.pem misp-docker/exim-macros
    zsazsa/docker/.env zsazsa/docker/volumes/config/__init__.py
    zsazsa/docker/volumes/scraper-config/scraper.py zsazsa/docker/volumes/scraper-config/feedlist.json)
hashes() { (cd "$SANDBOX" && sha256sum "${GENERATED[@]}" 2>&1); }

if out=$(PATH="$SPATH" bash "$SANDBOX/scripts/init.sh" 2>&1); then
    pass "init.sh runs"
else
    fail "init.sh runs" "$(tail -n 30 <<< "$out")"
fi
for f in "${GENERATED[@]}"; do
    check "init.sh wrote $f" test -s "$SANDBOX/$f"
done
check "init.sh creates the LAN network (ipvlan on LAN_PARENT)" \
    grep -q -- "network create -d ipvlan --subnet 10.231.19.0/24 --gateway 10.231.19.1 --ip-range 10.231.19.16/29 -o parent=eth0 -o ipvlan_mode=l2 cti-lan" \
    "$TMP/docker-network.log"

MENV="$SANDBOX/misp-docker/.env"
ZENV="$SANDBOX/zsazsa/docker/.env"
expect_eq "misp-docker/.env: BASE_URL" "https://$HOSTNAME_" "$(env_value "$MENV" BASE_URL)"
expect_eq "misp-docker/.env: ADMIN_ORG with a space" 'ADMIN_ORG="Test Org"' "$(grep '^ADMIN_ORG=' "$MENV")"
expect_eq "misp-docker/.env: COMPOSE_FILE" "docker-compose.yml:../deploy/misp-docker.override.yml" "$(env_value "$MENV" COMPOSE_FILE)"
for tag in CORE MODULES; do
    expect_eq "misp-docker/.env: ${tag}_RUNNING_TAG pinned to template.env" \
        "$(env_value misp-docker/template.env "${tag}_TAG")" "$(env_value "$MENV" "${tag}_RUNNING_TAG")"
done
for key in MYSQL_PASSWORD MYSQL_ROOT_PASSWORD REDIS_PASSWORD ADMIN_PASSWORD ENCRYPTION_KEY GPG_PASSPHRASE SUPERVISOR_PASSWORD; do
    expect_match "misp-docker/.env: $key generated" '^[A-Za-z0-9]{32}$' "$(env_value "$MENV" "$key")"
done
expect_match "misp-docker/.env: ADMIN_KEY generated (40 characters)" '^[A-Za-z0-9]{40}$' "$(env_value "$MENV" ADMIN_KEY)"
expect_eq "misp-docker/.env and zsazsa/docker/.env share the Redis password" \
    "$(env_value "$MENV" REDIS_PASSWORD)" "$(env_value "$ZENV" REDIS_PASSWORD)"
expect_eq "misp-docker/.env is private" 600 "$(stat -c %a "$MENV")"
expect_eq "zsazsa/docker/.env is private" 600 "$(stat -c %a "$ZENV")"
san=$(openssl x509 -in "$SANDBOX/misp-docker/ssl/cert.pem" -noout -ext subjectAltName 2>&1)
expect_match "certificate of misp-nginx names the hostname, misp-nginx and the LAN address" \
    "DNS:$HOSTNAME_, DNS:misp-nginx, IP Address:$LAN_IP" "$san"

# init.sh changes the example configurations with set_py, which appends a key
# that is missing. A key zsazsa or misp-scraper renamed would end up at the end
# of the file, where nothing reads it.
py_checks - "$SANDBOX" "$(env_value "$MENV" ADMIN_KEY)" "$(env_value "$MENV" REDIS_PASSWORD)" "$HOSTNAME_" << 'PY'
import ast, sys
root, admin_key, redis_password, hostname = sys.argv[1:5]

def assigned(path):
    tree = ast.parse(open(path).read(), path)
    values = {}
    for node in tree.body:
        if isinstance(node, ast.Assign):
            for t in node.targets:
                if isinstance(t, ast.Name):
                    try:
                        values[t.id] = ast.literal_eval(node.value)
                    except ValueError:
                        values[t.id] = ...
    return values

def compare(name, example, generated, expected):
    ex, gen = assigned(example), assigned(generated)
    added = sorted(set(gen) - set(ex))
    if added:
        print(f"FAIL\t{name}: init.sh only sets settings the example has\t"
              f"not in {example.split(root + '/')[-1]} (renamed upstream?): {', '.join(added)}")
    else:
        print(f"PASS\t{name}: init.sh only sets settings the example has")
    wrong = [f"{k} = {gen.get(k, '<missing>')!r}, expected {v!r}" for k, v in expected.items() if gen.get(k, "<missing>") != v]
    if wrong:
        print(f"FAIL\t{name}: values written by init.sh\t" + "\\n".join(wrong))
    else:
        print(f"PASS\t{name}: values written by init.sh ({len(expected)} settings)")

url = f"https://{hostname}"
compare("zsazsa config", f"{root}/zsazsa/config/__init__.py.example",
        f"{root}/zsazsa/docker/volumes/config/__init__.py", {
    "MISP_URL": url, "MISP_WEBAPP_URL": url, "MISP_KEY": admin_key, "MISP_WEBAPP_KEY": admin_key,
    "MISP_VERIFYCERT": False, "MISP_WEBAPP_VERIFYCERT": False, "MISP_SCRAPER_ENABLED": True, "OPENAI_API_KEY": "",
    "MISP_SESSION_REDIS_HOST": "redis", "MISP_SESSION_REDIS_PORT": 6379, "MISP_SESSION_REDIS_DB": 0,
    "MISP_SESSION_REDIS_PASSWORD": redis_password, "SCRAPER_REDIS_HOST": "redis", "SCRAPER_REDIS_PORT": 6379,
    "SCRAPER_REDIS_PASSWORD": redis_password, "JOB_REDIS_HOST": "redis", "JOB_REDIS_PORT": 6379,
    "JOB_REDIS_PASSWORD": redis_password, "MISP_SESSION_REDIRECT_TO_LOGIN": True,
})
secret = assigned(f"{root}/zsazsa/docker/volumes/config/__init__.py").get("SECRET_KEY", "")
print(("PASS" if isinstance(secret, str) and len(secret) == 64 else "FAIL") + "\tzsazsa config: SECRET_KEY generated")
compare("misp-scraper config", f"{root}/zsazsa/docker/scraper.py.zsazsa",
        f"{root}/zsazsa/docker/volumes/scraper-config/scraper.py", {
    "misp_url": "https://misp-nginx:8443", "misp_key": admin_key, "misp_verifycert": False,
    "misp_distribution": 0, "rawhtml_distribution": 0,
})
PY
# The configuration is a Python module that zsazsa imports.
check "zsazsa config runs as Python" python3 -c 'import runpy, sys; runpy.run_path(sys.argv[1])' \
    "$SANDBOX/zsazsa/docker/volumes/config/__init__.py"
check "misp-scraper config runs as Python" python3 -c 'import runpy, sys; runpy.run_path(sys.argv[1])' \
    "$SANDBOX/zsazsa/docker/volumes/scraper-config/scraper.py"

before=$(hashes)
if out=$(PATH="$SPATH" bash "$SANDBOX/scripts/init.sh" 2>&1); then
    pass "init.sh runs a second time"
else
    fail "init.sh runs a second time" "$(tail -n 30 <<< "$out")"
fi
after=$(hashes)
if [[ "$before" == "$after" ]]; then
    pass "a second run changes nothing (passwords, keys, certificate and configuration kept)"
else
    fail "a second run changes nothing" "$(diff <(echo "$before") <(echo "$after"))"
fi

# A missing setting stops init.sh before it writes anything.
copy_repo "$TMP/repo-missing"
grep -v '^PROXY_IP=' "$SANDBOX/deploy/settings.env" > "$TMP/repo-missing/deploy/settings.env"
out=$(PATH="$SPATH" bash "$TMP/repo-missing/scripts/init.sh" 2>&1)
status=$?
if (( status != 0 )) && [[ "$out" == *"Set PROXY_IP"* && ! -e "$TMP/repo-missing/misp-docker/.env" ]]; then
    pass "init.sh refuses a settings.env without PROXY_IP"
else
    fail "init.sh refuses a settings.env without PROXY_IP" "exit $status" "$out"
fi

# --- Compose configuration --------------------------------------------------------

section "Compose configuration of both stacks (with the .env files of init.sh)"

compose_json() {
    # Only what the .env files say: none of this shell's variables.
    (cd "$1" && env -i PATH="$SPATH" HOME="$HOME" ${DOCKER_CONFIG:+DOCKER_CONFIG="$DOCKER_CONFIG"} \
        docker compose config --format json 2> "$TMP/compose.err" > "$TMP/compose.json")
}

if ! docker compose version > /dev/null 2>&1; then
    fail "docker compose is not installed"
else
    for stack in misp-docker zsazsa/docker; do
        if compose_json "$SANDBOX/$stack"; then
            pass "docker compose config ($stack)"
            warnings=$(grep -iE 'warn|not set' "$TMP/compose.err" || true)
            if [[ -z "$warnings" ]]; then
                pass "no Compose warnings ($stack)"
            else
                fail "no Compose warnings ($stack)" "$warnings"
            fi
            cp "$TMP/compose.json" "$TMP/compose-${stack%%/*}.json"
        else
            fail "docker compose config ($stack)" "$(cat "$TMP/compose.err")"
        fi
    done
fi

if [[ -s "$TMP/compose-misp-docker.json" ]]; then
    py_checks - "$TMP/compose-misp-docker.json" "$SANDBOX" "$LAN_IP" "$HOSTNAME_" \
        "$(env_value misp-docker/template.env CORE_TAG)" "$(env_value misp-docker/template.env MODULES_TAG)" << 'PY'
import json, sys
cfg = json.load(open(sys.argv[1]))
root, lan_ip, hostname, core_tag, modules_tag = sys.argv[2:7]
services = cfg.get("services", {})

def result(ok, what, detail=""):
    print(("PASS" if ok else "FAIL") + "\t" + what + ("" if ok else "\t" + str(detail).replace("\n", "\\n")))

def mounts(svc):
    return {v.get("target"): v.get("source", "") for v in services.get(svc, {}).get("volumes", []) or []}

# Used by deploy/misp-docker.override.yml and by scripts/report.sh, post-install.sh, README.
for name in ["misp-core", "misp-nginx", "misp-modules", "db", "redis", "mail"]:
    result(name in services, f"service {name} exists", f"services: {', '.join(sorted(services))}")

for name, tag in [("misp-core", core_tag), ("misp-nginx", core_tag), ("misp-modules", modules_tag)]:
    image = services.get(name, {}).get("image", "")
    result(image.endswith(":" + tag), f"{name} runs the pinned image (:{tag})", image)

core = services.get("misp-core", {})
result(mounts("misp-core").get("/custom/files/customize_misp.sh", "").endswith("/deploy/misp/customize_misp.sh"),
       "misp-core mounts deploy/misp/customize_misp.sh", mounts("misp-core"))
result(str(core.get("healthcheck", {}).get("start_period", "")).startswith("15m"),
       "misp-core: start_period of the override (15m)", core.get("healthcheck"))
result(core.get("environment", {}).get("BASE_URL") == f"https://{hostname}", "misp-core: BASE_URL",
       core.get("environment", {}).get("BASE_URL"))

nginx = services.get("misp-nginx", {})
result(not nginx.get("ports"), "misp-nginx publishes no ports on the host", nginx.get("ports"))
lan = (nginx.get("networks") or {}).get("lan") or {}
result(lan.get("ipv4_address") == lan_ip, "misp-nginx has MISP_LAN_IP on the LAN network", nginx.get("networks"))
result("default" in (nginx.get("networks") or {}), "misp-nginx stays on misp-docker's network (zsazsa, misp-core)",
       nginx.get("networks"))
result(mounts("misp-nginx").get("/docker-entrypoint.d/05-zsazsa.sh", "").endswith("/deploy/nginx/05-zsazsa.sh"),
       "misp-nginx mounts deploy/nginx/05-zsazsa.sh", mounts("misp-nginx"))
env = nginx.get("environment", {})
result(env.get("NGINX_INTERNAL_HTTPS_PORT") == "8443" and env.get("NGINX_INTERNAL_HTTP_PORT") == "8080",
       "misp-nginx listens on MISP_HTTPS_PORT / MISP_HTTP_PORT", env)
dep = (nginx.get("depends_on") or {}).get("misp-core") or {}
result(dep.get("condition") == "service_healthy" and dep.get("restart") is True,
       "misp-nginx restarts with misp-core", dep)
result(mounts("mail").get("/etc/exim4/_docker_additional_macros", "").endswith("/misp-docker/exim-macros"),
       "mail mounts misp-docker/exim-macros", mounts("mail"))

net = cfg.get("networks", {}).get("lan", {})
result(net.get("external") is True and net.get("name") == "cti-lan", "the LAN network is the external cti-lan", net)
PY
fi

if [[ -s "$TMP/compose-zsazsa.json" ]]; then
    py_checks - "$TMP/compose-zsazsa.json" "$SANDBOX" "$HOSTNAME_" "$PROXY_IP" << 'PY'
import json, sys
cfg = json.load(open(sys.argv[1]))
root, hostname, proxy_ip = sys.argv[2:5]
services = cfg.get("services", {})

def result(ok, what, detail=""):
    print(("PASS" if ok else "FAIL") + "\t" + what + ("" if ok else "\t" + str(detail).replace("\n", "\\n")))

def mounts(svc):
    return {v.get("target"): v.get("source", "") for v in services.get(svc, {}).get("volumes", []) or []}

# deploy/zsazsa.override.yml names these; COMPOSE_PROFILES=scheduled,scraper starts all of them.
for name in ["webapp", "analyser", "imap-collector", "scraper-subscribe", "scraper-cron"]:
    result(name in services, f"service {name} exists and is started", f"services: {', '.join(sorted(services))}")

vol = f"{root}/zsazsa/docker/volumes"
for name in ["webapp", "analyser", "imap-collector"]:
    m = mounts(name)
    expected = {"/app/config": f"{vol}/config", "/app/data": f"{vol}/data", "/app/zsazsaprompts": f"{vol}/prompts"}
    result(all(m.get(k) == v for k, v in expected.items()),
           f"{name} mounts volumes/config, data and prompts (scripts/lib.sh, sync-prompts.sh)", m)
    hosts = services.get(name, {}).get("extra_hosts") or []
    hosts = hosts if isinstance(hosts, list) else [f"{k}={v}" for k, v in hosts.items()]
    result(any(h.replace(":", "=", 1) == f"{hostname}={proxy_ip}" for h in hosts),
           f"{name} reaches MISP_HOSTNAME through the reverse proxy", hosts)
    tz = services.get(name, {}).get("environment", {}).get("TZ")
    result(tz == "Europe/Amsterdam", f"{name}: TZ", tz)

for name in ["scraper-subscribe", "scraper-cron"]:
    svc = services.get(name, {})
    result(mounts(name).get("/config") == f"{vol}/scraper-config", f"{name} mounts volumes/scraper-config", mounts(name))
    result(svc.get("build", {}).get("context") == f"{root}/misp-scraper", f"{name} builds ../../misp-scraper",
           svc.get("build"))
    result(svc.get("restart") == "unless-stopped", f"{name}: restart unless-stopped", svc.get("restart"))
    result(svc.get("environment", {}).get("REDIS_HOST") == "redis", f"{name} uses MISP's Redis", svc.get("environment"))

web = services.get("webapp", {})
result(not web.get("ports"), "webapp publishes no ports on the host", web.get("ports"))
result(web.get("environment", {}).get("ZSAZSA_PORT") == "5000", "webapp listens on 5000 (05-zsazsa.sh)",
       web.get("environment"))
aliases = ((web.get("networks") or {}).get("default") or {}).get("aliases") or []
result("zsazsa" in aliases, "webapp is 'zsazsa' on misp-docker's network (05-zsazsa.sh)", web.get("networks"))
net = cfg.get("networks", {}).get("default", {})
result(net.get("external") is True and net.get("name") == "misp-docker_default",
       "zsazsa joins misp-docker_default", net)
PY
fi

# --- .github/scripts/upstream-pr.sh -------------------------------------------------

section ".github/scripts/upstream-pr.sh (title and body of the update PR)"

PR="$TMP/pr"
mkdir -p "$PR/.github/scripts" "$PR/misp-docker" "$PR/zsazsa"
cp .github/scripts/upstream-pr.sh "$PR/.github/scripts/"
cp UPSTREAM.md "$PR/"
cp misp-docker/template.env "$PR/misp-docker/"
printf '# Changelog\n\n- old entry\n' > "$PR/zsazsa/CHANGELOG.md"
(
    cd "$PR" &&
        git init -q &&
        git add -A &&
        git -c user.name=test -c user.email=test@test.example commit -qm base
) || fail "test repository for upstream-pr.sh"
old=$(awk -F'|' '/^\| `misp-docker\/`/ { gsub(/[` ]/, "", $4); print $4 }' UPSTREAM.md)
sed -i "s/$old/0123456789ab/" "$PR/UPSTREAM.md"
sed -i -E 's/^CORE_TAG=.*/CORE_TAG=v9.9.9/' "$PR/misp-docker/template.env"
printf -- '- new entry\n' >> "$PR/zsazsa/CHANGELOG.md"
echo "deploy/patches/misp-scraper/x.patch" > "$TMP/failed"

title=$(bash "$PR/.github/scripts/upstream-pr.sh" title 2>&1)
expect_eq "title names the folders that changed" "Upstream update: misp-docker 0123456" "$title"
title=$(bash "$PR/.github/scripts/upstream-pr.sh" title "$TMP/failed" 2>&1)
expect_eq "title warns about a failed patch" "⚠️ Upstream update: misp-docker 0123456 (patch failed)" "$title"
body=$(bash "$PR/.github/scripts/upstream-pr.sh" body "$TMP/failed" 2>&1)
expect_match "body: compare link for misp-docker" "misp-docker/compare/$old\.\.\.0123456789ab" "$body"
expect_match "body: unchanged folders" '`zsazsa/` \| unchanged' "$body"
expect_match "body: new MISP image version" $'\\+CORE_TAG=v9\\.9\\.9' "$body"
expect_match "body: zsazsa CHANGELOG lines" $'<summary>Show</summary>\n\n- new entry\n' "$body"
expect_match "body: failed patch" 'deploy/patches/misp-scraper/x\.patch' "$body"

# --- Needs the internet -------------------------------------------------------------

section "Pinned images exist"

if [[ -n "${CHECK_OFFLINE:-}" ]]; then
    skip "CHECK_OFFLINE is set"
elif [[ -s "$TMP/compose-misp-docker.json" ]]; then
    images=$(python3 -c 'import json, sys; print("\n".join(sorted({s["image"] for s in json.load(open(sys.argv[1]))["services"].values() if s.get("image")})))' "$TMP/compose-misp-docker.json")
    for image in $images; do
        check "$image" docker manifest inspect "$image"
    done
fi

section "scripts/update-upstream.sh (in a copy, from GitHub)"

if [[ -n "${CHECK_OFFLINE:-}" ]]; then
    skip "CHECK_OFFLINE is set"
else
    # Runtime files of a deployment, which the update has to keep, and a file
    # that upstream does not have, which it has to remove.
    U="$SANDBOX"
    mkdir -p "$U/misp-docker/files" "$U/misp-scraper/docker/config" "$U/zsazsa/docker/volumes/data"
    echo data > "$U/misp-docker/files/kept"
    echo data > "$U/misp-scraper/scraper.py"
    echo data > "$U/misp-scraper/docker/config/kept"
    echo data > "$U/zsazsa/docker/volumes/data/kept"
    echo stale > "$U/zsazsa/not-upstream"
    KEPT=(misp-docker/.env misp-docker/ssl/cert.pem misp-docker/exim-macros misp-docker/files/kept misp-scraper/scraper.py
        misp-scraper/docker/config/kept zsazsa/docker/.env zsazsa/docker/volumes/config/__init__.py
        zsazsa/docker/volumes/data/kept)
    before=$(cd "$U" && sha256sum "${KEPT[@]}")
    if out=$(UPSTREAM_FAILED_PATCHES="$TMP/failed-patches" bash "$U/scripts/update-upstream.sh" 2>&1); then
        pass "update-upstream.sh runs"
    else
        fail "update-upstream.sh runs" "$(tail -n 30 <<< "$out")"
    fi
    after=$(cd "$U" && sha256sum "${KEPT[@]}" 2>&1)
    if [[ "$before" == "$after" ]]; then
        pass "runtime files and data are kept"
    else
        fail "runtime files and data are kept" "$(diff <(echo "$before") <(echo "$after"))"
    fi
    check "files upstream does not have are removed" test ! -e "$U/zsazsa/not-upstream"
    check "no stash left behind" test ! -e "$U/.upstream-stash"
    check "UPSTREAM.md lists the three folders" test "$(grep -c '^| `' "$U/UPSTREAM.md")" -eq 3
    if [[ -s "$TMP/failed-patches" ]]; then
        fail "all patches apply to the current upstream" "$(cat "$TMP/failed-patches")"
    else
        pass "all patches apply to the current upstream"
    fi
fi

finish "tests/check.sh"
