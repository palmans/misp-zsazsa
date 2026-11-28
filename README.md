# MISP + misp-scraper + zsazsa on Docker

A ready-to-deploy Docker setup for the [zsazsa](https://github.com/zsazsa-project/zsazsa) CTI program management platform, together with the two components it builds on:

| Component | What it does | Upstream |
|---|---|---|
| **MISP** | Threat intelligence platform; zsazsa's data store and identity provider | [MISP/misp-docker](https://github.com/MISP/misp-docker) |
| **misp-scraper** | Turns RSS feeds and article URLs into MISP events | [cudeso/misp-scraper](https://github.com/cudeso/misp-scraper) |
| **zsazsa** | CTI program management: stakeholders, PIRs/GIRs, products, briefings, collection | [zsazsa-project/zsazsa](https://github.com/zsazsa-project/zsazsa) |

The three folders `misp-docker/`, `misp-scraper/` and `zsazsa/` are copies of their upstream repositories (see [UPSTREAM.md](UPSTREAM.md)), changed only by the patches in `deploy/patches/`. Everything specific to this deployment lives in `deploy/` and `scripts/`, and every site-specific value (hostname, addresses, e-mail, passwords) lives in files that git ignores.

## Contents

- [Architecture](#architecture)
- [Repository layout](#repository-layout)
- [Requirements](#requirements)
- [What you must configure](#what-you-must-configure)
- [Installation](#installation)
- [Reverse proxy](#reverse-proxy)
- [First run](#first-run)
- [Day-to-day operations](#day-to-day-operations)
- [Updating](#updating)
- [Tests](#tests)
- [Backup and restore](#backup-and-restore)
- [Troubleshooting](#troubleshooting)
- [Security notes and recommendations](#security-notes-and-recommendations)
- [Credits and licenses](#credits-and-licenses)

## Architecture

```
                 Browser
                    │  https://misp.example.com            (and /zsazsa/)
                    ▼
        Reverse proxy (TLS, e.g. Nginx Proxy Manager)
                    │  https://MISP_LAN_IP:MISP_HTTPS_PORT  (self-signed)
════════════════════╪════════════ LAN ═══════════════════════════════════
 Docker host        │
   ipvlan/macvlan   ▼
   network     ┌────────────┐
   "cti-lan"   │ misp-nginx │  /          → misp-core (PHP-FPM)
               │            │  /zsazsa/   → zsazsa webapp
               └─────┬──────┘
   bridge network    │  "misp-docker_default"
   ┌─────────────────┴──────────────────────────────────────────────┐
   │ misp-core   misp-modules   db (MariaDB)   redis (Valkey)   mail │
   │ zsazsa: webapp  analyser  imap-collector                       │
   │ misp-scraper: scraper-subscribe  scraper-cron                  │
   └────────────────────────────────────────────────────────────────┘
```

- **No ports are published on the Docker host.** `misp-nginx` gets an address of its own on the LAN through an `ipvlan` (or `macvlan`) Docker network, so it never conflicts with ports 80/443 or anything else running on the host. It is the only container reachable from the LAN.
- **zsazsa is served under MISP's own hostname**, at `https://<MISP_HOSTNAME>/zsazsa/`. `misp-nginx` proxies that path to the zsazsa container. This is required for zsazsa's single sign-on: zsazsa identifies the analyst from MISP's session cookie, which the browser only sends to MISP's hostname. Opening a zsazsa page without a MISP session shows MISP's login page and returns to that zsazsa page after the login; logging in on MISP itself lands in MISP as usual.
- **One Redis** (MISP's) is shared: zsazsa reads MISP's PHP sessions from it (single sign-on), sends article URLs to misp-scraper through it, and keeps its background-job state in it.
- zsazsa calls the MISP API on MISP's public URL, through the reverse proxy (needed for the single sign-on login redirect). misp-scraper talks to `misp-nginx` directly on the internal network.
- All containers restart automatically after a reboot of the Docker host (`restart: always` / `unless-stopped`).

## Repository layout

| Path | Purpose | In git |
|---|---|---|
| `deploy/settings.env.example` | Template of the site settings | yes |
| `deploy/settings.env` | **Your** site settings | no |
| `deploy/misp-docker.override.yml` | Compose override for misp-docker: no host ports, LAN address, configurable ports, zsazsa route | yes |
| `deploy/zsazsa.override.yml` | Compose override for zsazsa: no host ports, MISP reached through the proxy, restart policy | yes |
| `deploy/nginx/05-zsazsa.sh` | Adds the `/zsazsa/` location, and the return to zsazsa after a MISP login, to misp-nginx on every start | yes |
| `deploy/misp/customize_misp.sh` | Runs in misp-core on every start: `Security.force_https`, mail signing, default distribution, PHP session hardening | yes |
| `deploy/misp/post_install.py` | Taxonomies, users and API keys through MISP's API; run by `scripts/post-install.sh` | yes |
| `scripts/post-install.sh` | Once after the first start: taxonomies and dedicated API keys for zsazsa and misp-scraper | yes |
| `scripts/report.sh` | Read-only status report for checking and troubleshooting | yes |
| `scripts/lib.sh` | Helpers shared by the scripts | yes |
| `misp-docker/exim-macros` | Extra settings for the mail container, generated by `init.sh` | no |
| `deploy/patches/<folder>/*.patch` | Fixes upstream does not have (yet), applied by `update-upstream.sh`; e.g. misp-scraper follows NCSC-NL's advisory links to the advisory itself | yes |
| `deploy/reverse-proxy.example.conf` | Example configuration for a plain nginx reverse proxy | yes |
| `scripts/init.sh` | Generates all configuration, passwords, keys and the certificate from `deploy/settings.env` | yes |
| `scripts/update-upstream.sh` | Refreshes the three upstream folders and applies `deploy/patches/` | yes |
| `scripts/update.sh` | Updates the Docker host to the repository: `git pull`, `init.sh`, both stacks, prompt check | yes |
| `.github/workflows/upstream-update.yml` | Runs `update-upstream.sh` every Monday, opens a pull request with the upstream changes and runs the tests on it | yes |
| `tests/check.sh`, `tests/e2e.sh` | Tests that the deployment still works with the upstream folders (see [Tests](#tests)) | yes |
| `.github/workflows/tests.yml` | Runs the tests on pull requests, on pushes to `main` and for the upstream update | yes |
| `misp-docker/.env`, `misp-docker/ssl/` | Generated MISP configuration, passwords and certificate | no |
| `misp-docker/{configs,files,gnupg,logs}/` | MISP runtime data (created by the containers) | no |
| `zsazsa/docker/.env` | Generated zsazsa compose settings | no |
| `zsazsa/docker/volumes/` | zsazsa configuration (API keys), data, prompts and misp-scraper configuration | no |

## Requirements

- A Linux Docker host with **Docker Engine** and the **Compose plugin 2.24 or later** (`docker compose version`), plus `git` and `openssl`. A Docker host in a Proxmox LXC container works (use the `ipvlan` driver, see below).
- A **free address on the LAN** for `misp-nginx`, outside the DHCP pool of your router.
- A **reverse proxy** that terminates TLS for MISP's hostname, with a DNS record for that hostname pointing at it. The reverse proxy must run on **another machine than the Docker host** (see [Troubleshooting](#the-docker-host-cannot-reach-misp_lan_ip)).
- At least **6 GB RAM** for the whole stack (MISP with MariaDB alone uses about 2.5 GB with the default `INNODB_BUFFER_POOL_SIZE=2048M`; zsazsa, misp-scraper and the image builds need the rest) and 20 GB of disk. On a smaller host, lower `INNODB_BUFFER_POOL_SIZE` in `misp-docker/.env`.
- Outbound internet access for the containers (image pulls, feeds, scraped sites, optionally the OpenAI API).

## What you must configure

### Before installation: `deploy/settings.env`

Copy `deploy/settings.env.example` to `deploy/settings.env` and set:

| Setting | Meaning | Example |
|---|---|---|
| `MISP_HOSTNAME` | Public hostname of MISP; zsazsa is served at `https://<MISP_HOSTNAME>/zsazsa/` | `misp.example.com` |
| `ADMIN_EMAIL` | E-mail (login) of the MISP administrator created on first start | `admin@example.com` |
| `ADMIN_ORG` | Name of your organisation in MISP | `Example Org` |
| `TZ` | Timezone of the containers | `Europe/Amsterdam` |
| `MISP_LAN_IP` | LAN address of `misp-nginx`; the reverse proxy forwards to it | `192.168.1.19` |
| `MISP_HTTPS_PORT` | HTTPS port of `misp-nginx` on that address (> 1024) | `8443` |
| `MISP_HTTP_PORT` | HTTP port of `misp-nginx` (only redirects to HTTPS; > 1024) | `8080` |
| `LAN_NETWORK_NAME` | Name of the Docker network on the LAN | `cti-lan` |
| `LAN_DRIVER` | `ipvlan` (shares the host's MAC address; required in Proxmox LXC or behind MAC filtering) or `macvlan` | `ipvlan` |
| `LAN_PARENT` | LAN interface of the Docker host (`ip -br addr`) | `eth0` |
| `LAN_SUBNET` / `LAN_GATEWAY` | Your LAN and its router | `192.168.1.0/24` / `192.168.1.1` |
| `LAN_IP_RANGE` | Addresses Docker may use on the LAN; must contain `MISP_LAN_IP` and lie outside the DHCP pool | `192.168.1.16/29` |
| `PROXY_IP` | Address of the reverse proxy. MISP trusts its `X-Forwarded-For` header; the zsazsa containers reach `MISP_HOSTNAME` through it | `192.168.1.105` |
| `PROXY_CERT_VALID` | `true` when the reverse proxy has a publicly trusted certificate (e.g. Let's Encrypt), `false` for self-signed/private CA | `true` |

Use one `KEY=value` per line, no inline comments. Quotes are optional, also for values with spaces.

`scripts/init.sh` generates everything else: all passwords and keys (MariaDB, Redis, MISP admin password and API key, encryption key, GPG passphrase, supervisor, zsazsa and misp-scraper secrets), a self-signed certificate for `misp-nginx`, and the zsazsa and misp-scraper configuration.

### After the first start (in the web interfaces)

| Where | What |
|---|---|
| MISP | Change the administrator password, enable two-factor authentication, enable the taxonomies zsazsa and misp-scraper use |
| MISP | Create dedicated users and API keys for zsazsa and misp-scraper (they start with the admin key) |
| MISP, optional | Outgoing mail: set `SMARTHOST_*` in `misp-docker/.env` |
| zsazsa | Setup wizard: organisation, collection sources, AI provider (OpenAI API key or a local OpenAI-compatible LLM), focus points, notifications |
| zsazsa | Single sign-on: save the SSO settings once and run "Test single sign-on" |
| misp-scraper, optional | The RSS feeds to scrape: `zsazsa/docker/volumes/scraper-config/feedlist.json` |

## Installation

All commands run on the Docker host, as root (or a user in the `docker` group with sudo for the `chown` steps). The examples install into `/opt/misp-zsazsa`.

### 1. Prepare the network

- Exclude `MISP_LAN_IP` (and preferably all of `LAN_IP_RANGE`) from the DHCP pool of your router.
- Create a DNS record for `MISP_HOSTNAME` pointing at your reverse proxy.
- `macvlan` only: if the Docker host is a VM or container on Proxmox with the firewall enabled on its network device, disable MAC filtering there (or simply use `ipvlan`).

### 2. Get the code and your settings

```bash
git clone <your-repository-url> /opt/misp-zsazsa
cd /opt/misp-zsazsa
cp deploy/settings.env.example deploy/settings.env
nano deploy/settings.env
```

### 3. Generate the configuration

```bash
bash scripts/init.sh
```

This writes `misp-docker/.env`, `misp-docker/ssl/`, `zsazsa/docker/.env`, `zsazsa/docker/volumes/`, and creates the LAN network. Check the network:

```bash
docker network inspect cti-lan -f '{{.Driver}} {{.Options}} {{json .IPAM.Config}}'
```

Running `init.sh` again is safe: it re-applies `settings.env` to the `.env` files but never replaces existing passwords, keys, the certificate or the zsazsa/misp-scraper configuration.

### 4. Start MISP

```bash
cd /opt/misp-zsazsa/misp-docker
docker compose pull
docker compose up -d
docker compose ps                  # wait until misp-core and misp-nginx are "healthy"
docker compose logs -f misp-core   # the first start initialises the database and takes a few minutes
```

The administrator credentials are in `misp-docker/.env`:

```bash
grep -E '^ADMIN_(EMAIL|PASSWORD)=' /opt/misp-zsazsa/misp-docker/.env
```

From another machine on the LAN (not from the Docker host itself), `curl -kI https://<MISP_LAN_IP>:<MISP_HTTPS_PORT>/users/login` should answer `200` (or a redirect).

### 5. Configure the reverse proxy

See [Reverse proxy](#reverse-proxy), then open `https://<MISP_HOSTNAME>` and log in.

### 6. Start zsazsa and misp-scraper

```bash
cd /opt/misp-zsazsa/zsazsa/docker
docker compose build
docker compose up -d
docker compose ps
docker compose logs -f webapp scraper-subscribe
```

This starts five containers: `webapp`, `analyser` (hourly), `imap-collector` (every 15 minutes), `scraper-subscribe` (URLs pushed by zsazsa) and `scraper-cron` (RSS feeds, hourly). The intervals are in `zsazsa/docker/.env`.

### 7. Taxonomies and dedicated API keys

```bash
cd /opt/misp-zsazsa
bash scripts/post-install.sh
```

zsazsa and misp-scraper start with the key of the MISP administrator, a site admin: whoever obtains it controls all of MISP, and everything both tools do is logged under the administrator's name. This script, run once:

- enables the taxonomies they tag with: `tlp`, `workflow`, `admiralty-scale` and `cti-evaluation`. Of `tlp` only the TLP 2.0 levels are enabled (`tlp:red`, `tlp:amber`, `tlp:amber+strict`, `tlp:green`, `tlp:clear`); `tlp:white`, `tlp:ex:chr` and `tlp:unclear` stay off and are hidden if they exist. Change `TAXONOMIES` in the script to choose otherwise;
- creates a MISP user for each, `<admin>+zsazsa@<domain>` and `<admin>+scraper@<domain>`, with an API key that only works from the address that tool calls from: the Docker host's address for zsazsa (it goes through the reverse proxy), misp-docker's network for misp-scraper;
- puts the keys in their configuration and restarts them.

Existing users are left alone; `--new-keys` adds a fresh key to them (revoke the old one under *Administration → List Users →* the user *→ Auth keys*), `--no-ip-limit` leaves the keys unrestricted.

Roles: misp-scraper gets *Org Admin*. zsazsa gets a role of its own, *zsazsa*, which the script creates with exactly what zsazsa checks its key for: add, modify and publish events (also those of the organisation), tag them and create tags, sightings, galaxies and analyst data, API access, and `perm_sync` (zsazsa reads MISP's instance UUID with it, for the session cookie name). It has no site admin and, unlike *Org Admin*, cannot manage users. `perm_sync` would also let the key push events in the name of another organisation; the key only works from the Docker host's address. Running the script again gives an existing zsazsa user this role. The script also fills in zsazsa's `MISP_SESSION_COOKIE_NAME` when it is empty.

### 8. Finish the setup in the browser

See [First run](#first-run).

## Reverse proxy

Forward `https://<MISP_HOSTNAME>` to **`https://<MISP_LAN_IP>:<MISP_HTTPS_PORT>`**. The scheme must be `https` (the HTTP port only redirects back to the public URL) and the backend certificate is self-signed, so certificate verification towards the backend must be off. zsazsa needs no rule of its own.

**Nginx Proxy Manager** — add a Proxy Host:

| Tab | Setting |
|---|---|
| Details | Domain names: `MISP_HOSTNAME`; Scheme: `https`; Forward hostname/IP: `MISP_LAN_IP`; Forward port: `MISP_HTTPS_PORT`; Block common exploits: on |
| SSL | Your certificate; Force SSL, HTTP/2 and HSTS: on |
| Advanced | `client_max_body_size 50M;`<br>`proxy_read_timeout 300s;`<br>`proxy_send_timeout 300s;` |

NPM does not verify backend certificates, and it passes the `Host` and `X-Forwarded-*` headers MISP needs.

**Plain nginx** — see [`deploy/reverse-proxy.example.conf`](deploy/reverse-proxy.example.conf).

If you restrict access with an access list on the reverse proxy, allow the Docker host's own address too: the zsazsa containers call MISP's API through the proxy.

## First run

1. **MISP** — log in at `https://<MISP_HOSTNAME>` with `ADMIN_EMAIL` / `ADMIN_PASSWORD`, change the password, and enable two-factor authentication (*My Profile*).
2. **Diagnostics** — *Administration → Server Settings & Maintenance → Diagnostics*. What remains after this setup is expected: see [MISP diagnostics](#misp-diagnostics).
3. **zsazsa** — open `https://<MISP_HOSTNAME>/zsazsa/`. As a MISP site admin you get zsazsa's setup wizard (also at `/zsazsa/config/setup`): organisation, collection sources, AI, focus points and notifications. AI features need an OpenAI API key or a local OpenAI-compatible endpoint (e.g. Ollama).
4. **Single sign-on** — in zsazsa, *Settings → System → Single sign-on*: save once (zsazsa then detects MISP's cookie name) and press **Test single sign-on**. Redis host, password and database are already filled in by `init.sh`.
5. **Dedicated API keys** — done by `scripts/post-install.sh` ([installation step 7](#7-taxonomies-and-dedicated-api-keys)). To do it by hand: *Administration → Add User* (role *Org Admin*, or for zsazsa a role with the permissions under [step 7](#7-taxonomies-and-dedicated-api-keys)), then the user's *Auth keys → Add authentication key*, and put the key in zsazsa's *Settings → Connections* and *Sources → MISP scraper*, and in `misp_key` of `zsazsa/docker/volumes/scraper-config/scraper.py`.
6. **Feeds** — edit `zsazsa/docker/volumes/scraper-config/feedlist.json` and restart `scraper-cron`, or trigger a run now (see below).

## Day-to-day operations

Run MISP commands from `misp-docker/` and zsazsa/misp-scraper commands from `zsazsa/docker/`: Compose reads the `.env` file (and with it the overrides) from the current directory.

```bash
# Status
cd /opt/misp-zsazsa/misp-docker   && docker compose ps
cd /opt/misp-zsazsa/zsazsa/docker && docker compose ps

# Restart after changing configuration
docker compose restart                       # all services of that stack
docker compose up -d                         # after changing .env or settings.env (recreates containers)

# Stop / start (data is kept)
docker compose down
docker compose up -d

# zsazsa / misp-scraper: run now instead of waiting for the interval
docker compose exec webapp python run_analyser.py
docker compose exec webapp python run_imap_collector.py
docker compose run --rm scraper-cron cron

# MISP command line (cake)
cd /opt/misp-zsazsa/misp-docker
docker compose exec misp-core sudo -u www-data /var/www/MISP/app/Console/cake Admin getSetting MISP.baseurl
docker compose exec misp-core sudo -u www-data /var/www/MISP/app/Console/cake user change_pw <email> '<new password>'
```

After changing `deploy/settings.env`, run `bash scripts/init.sh` and then `docker compose up -d` in both stacks. Settings that live in the zsazsa or misp-scraper configuration (MISP URL, API keys, Redis) are not rewritten by `init.sh`: change them in `zsazsa/docker/volumes/` or on zsazsa's Settings page.

The stacks show up in Portainer as stacks created outside Portainer ("limited" control): manage them with the commands above.

## Updating

The *Upstream update* workflow (`.github/workflows/upstream-update.yml`) runs `scripts/update-upstream.sh` on GitHub every Monday, and on demand under *Actions → Upstream update → Run workflow*. When upstream changed, it opens or updates one pull request on the branch `upstream/update`, with links to the upstream commits, the new MISP image versions, the lines added to zsazsa's CHANGELOG and the patches that no longer apply (label `patch-failed`). It then runs the [tests](#tests) on that branch and reports the result on the pull request as the status *Upstream update / tests* (and in a comment when they fail). The workflow needs *Settings → Actions → General → Workflow permissions → Allow GitHub Actions to create and approve pull requests*. Once the tests are done, it requests a review from the GitHub users in the repository variable `UPSTREAM_NOTIFY` (*Settings → Secrets and variables → Actions → Variables*, logins separated by spaces; `epalmans` when it is not set) and mentions them in a comment with the result, so they get a notification (web, e-mail, GitHub Mobile, as their notification settings say), also when an open pull request was only updated.

Review and merge it once that status is green, then update the Docker host:

```bash
cd /opt/misp-zsazsa
sudo bash scripts/update.sh
```

`update.sh` shows the incoming commits, new MISP image versions and the lines added to zsazsa's CHANGELOG, asks before it changes anything, and then does the steps below from `git pull` on (fast-forward only; it refuses when files git tracks were changed on the host): `init.sh`, `docker compose pull` and `up` for MISP, `build --pull` and `up` for zsazsa and misp-scraper (each until healthy), and lists the prompts that differ (`sync-prompts.sh`). What stays manual it prints at the end: the "Upgrading" notes, prompts to take over, migrations. Running it again is safe. `--yes` skips the question, `--skip-git` leaves the checkout as it is (after running `update-upstream.sh` yourself), `--no-image-pull` uses the images on the host.

By hand (without the pull request, or without `update.sh`):

```bash
cd /opt/misp-zsazsa
bash scripts/update-upstream.sh    # refreshes misp-docker/, misp-scraper/, zsazsa/ and UPSTREAM.md
git diff --stat                    # review upstream changes
bash scripts/init.sh               # applies the new MISP image tags to misp-docker/.env

cd misp-docker      && docker compose pull && docker compose up -d
cd ../zsazsa/docker && docker compose build --pull && docker compose up -d
```

Then:

- **Patches.** A patch that no longer applies is listed at the end of `update-upstream.sh`: upstream changed that code, or fixed the problem itself. Check upstream, then update or remove the patch.
- **Read the "Upgrading" notes** at the top of `zsazsa/CHANGELOG.md`. They say what an update needs beyond a rebuild.
- **Prompts.** zsazsa keeps its AI prompts in `zsazsa/docker/volumes/prompts`, so edits on its Prompts tab survive an update, and a prompt the update changes is not taken over by itself. `bash scripts/sync-prompts.sh` lists the prompts that differ from the shipped ones; `bash scripts/sync-prompts.sh --apply <prompt.md> ...` takes the ones the CHANGELOG names (without names: all of them, also those you edited). Old copies go to `zsazsa/docker/volumes/data/prompts-backup/`.
- **Migrations.** zsazsa's *Settings → System → Migration* lists one-off scripts for data stored by older releases. Each has a dry run; run the ones whose dry run reports changes. On an installation that started with a recent release they usually find nothing.
- **Commit** the updated folders, so the repository matches what runs. Running `update-upstream.sh` on another checkout (your workstation) and pulling on the Docker host works as well; then run only the `init.sh` and `docker compose` steps on the host.

Read the upstream release notes before updating MISP across minor versions.

The MISP images are pinned to the version in `misp-docker/template.env` (`CORE_RUNNING_TAG`, `MODULES_RUNNING_TAG`), so a `docker compose pull` alone never upgrades MISP unexpectedly. Avoid automatic updaters such as Watchtower for MISP.

## Tests

Upstream can change what this deployment relies on: a renamed setting, service or mount point, a patch that no longer applies, a MISP image that is not published (yet). Two scripts check that, and the *Tests* workflow (`.github/workflows/tests.yml`) runs them on GitHub for every pull request, for every push to `main`, and for the pull request of the *Upstream update* workflow (which calls it: a pull request a workflow opens starts no other workflows by itself).

| Script | What it checks | Needs | Time |
|---|---|---|---|
| `tests/check.sh` | Our scripts (syntax, ShellCheck, file modes); the patches of `deploy/patches/` are in the upstream folders; what `deploy/` and `scripts/` rely on in upstream (settings, services, mount points, nginx and misp-core entrypoints, uid 1000); `scripts/lib.sh`; `scripts/init.sh` run twice in a copy (the configuration it writes, nothing appended that upstream renamed, nothing changed on the second run); the Compose configuration of both stacks with the overrides; the PR text of the update workflow; that the pinned images exist; `scripts/update-upstream.sh` keeps the runtime files | bash, git, python3, openssl, the docker CLI (no daemon) | 1–2 min |
| `tests/e2e.sh` | Installs everything on the Docker host as in [Installation](#installation), in a copy of the repository, with a reverse proxy made from `deploy/reverse-proxy.example.conf` on a stand-in LAN, runs `post-install.sh` and checks it the way it is used: MISP through the proxy and on `MISP_LAN_IP`, `/zsazsa/`, the way back to zsazsa after a MISP login, single sign-on, zsazsa and misp-scraper calling MISP with their own (address-limited) keys, misp-scraper listening on Redis, what `customize_misp.sh` sets, `sync-prompts.sh`, `report.sh` (secrets masked), the database backup, no restarting containers, and a clean checkout afterwards (no file git tracks changed, so `git pull` keeps working; everything the deployment wrote in `.gitignore`). With `--upgrade-from <ref>` it installs that version first, then updates with `scripts/update.sh` as in [Updating](#updating) (its `git pull` included), and checks it all again and that MISP's data survived. What fails on the version before the update is reported as a warning only: that version is what is merged already, and a pull request may be the fix | root, Docker, ~6 GB RAM | 20–40 min |

On GitHub, `e2e (install)` installs the pull request as a new deployment and `e2e (update)` updates its base branch to it. A failed run lists what failed in the job summary, and prints the container logs and the report of `report.sh` in the *Logs* step. By hand: *Actions → Tests → Run workflow* with the branch to test, for example `upstream/update`.

Locally:

```bash
bash tests/check.sh                              # anywhere; CHECK_OFFLINE=1 skips what needs the internet
sudo bash tests/e2e.sh                           # on a spare Docker host or VM
sudo bash tests/e2e.sh --upgrade-from main --keep
```

`tests/e2e.sh` uses the names of a real deployment (Compose projects `misp-docker` and `zsazsa`, network `cti-lan`) and refuses to run where they exist: never run it on the Docker host of the deployment itself.

## Backup and restore

What to back up:

| Data | Where |
|---|---|
| MISP database | Docker volume `misp-docker_mysql_data` (dump it, see below) |
| MISP files, configuration, GPG keys, certificate, secrets | `misp-docker/{files,configs,gnupg,ssl}/`, `misp-docker/.env` |
| zsazsa and misp-scraper configuration and data | `zsazsa/docker/volumes/`, `zsazsa/docker/.env` |
| Site settings | `deploy/settings.env` |

```bash
BACKUP=/var/backups/misp-zsazsa/$(date +%F); mkdir -p "$BACKUP"
cd /opt/misp-zsazsa/misp-docker
docker compose exec -T db sh -c 'exec mariadb-dump --single-transaction -uroot -p"$MYSQL_ROOT_PASSWORD" "$MYSQL_DATABASE"' | gzip > "$BACKUP/misp-db.sql.gz"
tar czf "$BACKUP/files.tgz" -C /opt/misp-zsazsa \
    misp-docker/.env misp-docker/files misp-docker/configs misp-docker/gnupg misp-docker/ssl \
    zsazsa/docker/.env zsazsa/docker/volumes deploy/settings.env
```

Restore on a fresh checkout: extract `files.tgz` into `/opt/misp-zsazsa`, run `bash scripts/init.sh` (it keeps the restored secrets), start only the database (`docker compose up -d db`), load the dump (`gunzip -c misp-db.sql.gz | docker compose exec -T db sh -c 'exec mariadb -uroot -p"$MYSQL_ROOT_PASSWORD" "$MYSQL_DATABASE"'`), then start everything as in the installation.

The backup contains all passwords and API keys: store it encrypted.

## Troubleshooting

`bash scripts/report.sh` collects the state of both stacks into `/tmp/misp-zsazsa-report.txt`: containers, restarts, networks, effective settings, MISP workers, Redis and database figures, and the recent errors of every component. It only reads, and masks passwords and keys; hostnames and addresses stay in, so read it before you share it.

### MISP diagnostics

*Administration → Server Settings & Maintenance → Diagnostics* checks the installation. `deploy/misp/customize_misp.sh` already sets `Security.force_https`, `GnuPG.sign`, `MISP.default_event_distribution` (your organisation only) and PHP session strict mode and ID bits on every start, and the MariaDB and PHP values of misp-docker match MISP's recommendations. What remains is expected:

| Diagnostics item | Why it stays |
|---|---|
| *SQL database configuration* | Columns are *default / recommended / current*: the current values already are the recommended ones |
| *Schema status*: `cake_sessions.id`, `galaxies.distribution` differ | Collation/type differences of a fresh database; MISP itself marks them as possibly benign, and the DB version and migrations are up to date |
| *Email: STARTTLS is not enabled* | MISP hands mail to the mail container over misp-docker's internal network; the relay connection is configured there |
| *Full email body … without encryption* | A choice: set `GnuPG.bodyonlyencrypted` to send only a link to users without a GPG key |
| *Attachment scanning* | Optional: needs a ClamAV module (`Plugin.AttachmentScan_*`) and its memory |
| *Gathering / Cortex / AI module system not enabled* | Not used: zsazsa calls its own LLM provider |
| *Update Authkeys to advanced Authkeys* | Always shown; misp-docker enables advanced authkeys from the start |
| *Security audit* run with `cake Admin securityAudit` | On the command line the HTTPS check always fails (no web request); the web page shows the real result |

Two-factor authentication for all users (`Security.otp_required`) is not forced by this setup: enable it once every user has set up TOTP.

### Where the logs are

| Component | Command or file |
|---|---|
| MISP start-up, initialisation, workers | `docker compose logs -f misp-core` (in `misp-docker/`) |
| MISP application errors | `misp-docker/logs/error.log`, `debug.log`, `exec-errors.log`; also *Administration → Server Settings → Diagnostics* and *Audit → Logs* in the web interface |
| Web server (incl. `/zsazsa/` proxy) | `docker compose logs -f misp-nginx` |
| Database / Redis / modules / mail | `docker compose logs db`, `redis`, `misp-modules`, `mail` |
| zsazsa web app | `docker compose logs -f webapp` (in `zsazsa/docker/`) |
| zsazsa's own log (pipeline, SSO decisions, MISP calls) | `zsazsa/docker/volumes/data/analyser.log` |
| zsazsa analyser / IMAP collector | `docker compose logs analyser`, `imap-collector` |
| misp-scraper | `docker compose logs scraper-subscribe scraper-cron` and `zsazsa/docker/volumes/scraper-config/scraper.log` (raise `logging_level` in `scraper.py` to `info` or `debug` for more) |
| Container health | `docker inspect -f '{{json .State.Health}}' misp-docker-misp-core-1` |
| Restarts, crashes, OOM kills | `docker events --since 1h`, `docker inspect -f '{{.RestartCount}} {{.State.OOMKilled}}' <container>` |

Useful checks:

```bash
# The effective compose configuration (overrides applied)
docker compose config

# nginx configuration inside misp-nginx, including the /zsazsa/ locations
cd misp-docker && docker compose exec misp-nginx nginx -T | grep -A12 'zsazsa CTI'

# Redis reachable with the configured password
docker compose exec redis sh -c 'valkey-cli -a "$REDIS_PASSWORD" --no-auth-warning ping'

# zsazsa reaches MISP through the reverse proxy
cd zsazsa/docker && docker compose exec webapp python -c "import config, ssl, urllib.request; c = None if config.MISP_WEBAPP_VERIFYCERT else ssl._create_unverified_context(); print(urllib.request.urlopen(config.MISP_WEBAPP_URL + '/users/login', context=c).status)"
```

### misp-nginx does not start

- *`network cti-lan not found`* — the LAN network does not exist on this host: run `bash scripts/init.sh` on the Docker host.
- *`Address already in use`* — `MISP_LAN_IP` is taken by another device or container. Pick a free address inside `LAN_IP_RANGE`.
- *`BASE_URL starts with https://, but SSL certificate is NOT present`* — `misp-docker/ssl/cert.pem` or `key.pem` is missing: run `init.sh`.
- *`key.pem exists but is not readable by uid 101`* — `chgrp 101 misp-docker/ssl/key.pem && chmod 640 misp-docker/ssl/key.pem`.
- *`failed to create the ipvlan/macvlan port`* or no traffic at all — wrong `LAN_PARENT`; with `macvlan` in Proxmox or on a VM, MAC filtering drops the traffic: use `LAN_DRIVER=ipvlan` (remove the network with `docker network rm cti-lan` while misp-nginx is down, then run `init.sh` again).

### The Docker host cannot reach MISP_LAN_IP

Expected: with `ipvlan` and `macvlan`, the host and its containers on the LAN network cannot talk to each other directly. Test from another machine. This is also why the reverse proxy must run elsewhere, and why the zsazsa containers reach MISP through the reverse proxy.

### MISP_LAN_IP works from the LAN, not from a VPN or another subnet

misp-nginx sits on two networks. Its replies to clients outside the LAN subnet follow its default route; through misp-docker's bridge they would leave NATed from the Docker host's address and be dropped by the client. The override gives the LAN network `gw_priority: 1`, so the default route is the LAN gateway (needs Docker Engine 28 or later). Check it with `nsenter -t $(docker inspect -f '{{.State.Pid}}' misp-docker-misp-nginx-1) -n ip route`: the `default via` line must name `LAN_GATEWAY`. The router must also route the VPN's subnet to the LAN and allow it in its firewall.

### MISP through the reverse proxy

- *502 Bad Gateway* — misp-nginx is not running or not healthy (`docker compose ps`), or the proxy forwards to the wrong address, port or scheme (must be `https://MISP_LAN_IP:MISP_HTTPS_PORT`). A 502 page from nginx itself (not from the proxy) means misp-core is still starting, or misp-nginx still uses misp-core's previous address after misp-core was recreated: `docker compose restart misp-nginx`. The override restarts misp-nginx along with misp-core when Compose recreates it.
- *Too many redirects* — the proxy forwards to the HTTP port; use the HTTPS port.
- *Login form says the request was black-holed / CSRF errors* — the browser URL differs from `BASE_URL` in `misp-docker/.env`, or the proxy does not pass the `Host` header.
- *Uploads fail* — raise `client_max_body_size` on the proxy (and `NGINX_CLIENT_MAX_BODY_SIZE`/`PHP_UPLOAD_MAX_FILESIZE`/`PHP_POST_MAX_SIZE` in `misp-docker/.env`). All are 50 MB here. zsazsa's threat report import (`REPORT_IMPORT_MAX_MB`, 30 MB) stores the PDF in MISP base64-encoded, a third larger: raise these limits with it.
- *The first start takes long / misp-core unhealthy* — the database is initialised on the first start; follow `docker compose logs -f misp-core` until *MISP is now live*, then run `docker compose up -d` again if misp-nginx was left in the *Created* state. The override gives misp-core 15 minutes before a failed health check counts. MariaDB reserves `INNODB_BUFFER_POOL_SIZE` (2 GB by default): lower it in `misp-docker/.env` on small hosts.

### zsazsa

- *`/zsazsa/` returns 404* — the location is missing in misp-nginx. `docker compose logs misp-nginx | grep 05-zsazsa` shows whether the script ran; *"Ignoring ..., not executable"* means `chmod +x deploy/nginx/05-zsazsa.sh` (done by `init.sh`), then `docker compose up -d --force-recreate misp-nginx`.
- *`/zsazsa/` returns 502/504* — the zsazsa web app is down or not on misp-docker's network: `docker compose ps` in `zsazsa/docker/`, `docker network inspect misp-docker_default`. Start MISP before zsazsa: zsazsa joins MISP's network.
- *After logging in you land in zsazsa instead of MISP* — you opened a zsazsa page without a session in the 15 minutes before; misp-nginx remembered it in the `zsazsa_return` cookie. It is used once.
- *zsazsa does not recognise you / login loop* — use **Test single sign-on** on zsazsa's Settings page; zsazsa must be opened under `https://<MISP_HOSTNAME>/zsazsa/`. `WRONGPASS` in `analyser.log` means the `MISP_SESSION_REDIS_PASSWORD` in zsazsa's configuration differs from `REDIS_PASSWORD` in `misp-docker/.env`.
- *`CERTIFICATE_VERIFY_FAILED`* — the reverse proxy's certificate is not publicly trusted: set `MISP_VERIFYCERT` and `MISP_WEBAPP_VERIFYCERT` to `False` in `zsazsa/docker/volumes/config/__init__.py` and restart.
- *Connection refused/timeouts to MISP* — check `PROXY_IP` and `MISP_HOSTNAME` in `zsazsa/docker/.env` (they become an `/etc/hosts` entry in the containers) and any access list on the reverse proxy.
- *Permission denied in `/app/config` or `/app/data`* — `chown -R 1000:1000 zsazsa/docker/volumes`.

### Mail

- *`530 5.7.0 Authentication required`* in `/var/log/exim4/mainlog` of the mail container — exim did not log in: `SMARTHOST_ALIASES` is empty, or the relay offers no STARTTLS (see `SMARTHOST_ALLOW_PLAINTEXT_AUTH` under [Security notes](#security-notes-and-recommendations)). Check whether the relay offers STARTTLS from the Docker host with `openssl s_client -starttls smtp -connect <relay>:<port> < /dev/null`: a certificate means yes, `Didn't find STARTTLS in server response` means no.
- Frozen messages in `docker compose exec mail exim -bp` — remove them with `docker compose exec mail sh -c 'exim -bpru | awk "{print \$3}" | xargs -r exim -Mrm'`, or retry with `exim -qff`.
- MISP's "From" address is `MISP.email`; a relay that sends through Microsoft Graph or a mail provider usually only accepts senders it is allowed to send as.

### misp-scraper

- *`misp-scraper: not starting until the configuration is fixed`* — `misp_url` or `misp_key` is missing or `scraper.py` does not load. Fix `zsazsa/docker/volumes/scraper-config/scraper.py`; the container restarts on its own.
- *Events do not appear in zsazsa* — zsazsa recognises scraper events by `SCRAPER_MARKER_TAG` (`zsazsa:source="misp-scraper"`), which must be in `misp_scraper_tags_local` in `scraper.py` (it is by default).
- *URLs pushed from zsazsa are never scraped* — `scraper-subscribe` must be running; the Redis channel (`redis_channel` / `SCRAPER_REDIS_CHANNEL`, default `urls`) and password must match.

## Security notes and recommendations

- **Secrets stay out of git.** `.gitignore` excludes `deploy/settings.env`, all `.env` files, certificates and `zsazsa/docker/volumes/`. Check with `git status --ignored` before committing; a pre-commit secret scanner such as [gitleaks](https://github.com/gitleaks/gitleaks) adds a safety net.
- **Only misp-nginx is on the LAN**, and only behind the reverse proxy is it meant to be used. Containers on an `ipvlan`/`macvlan` network bypass the Docker host's firewall: restrict access to `MISP_LAN_IP` to the reverse proxy on your router or VLAN.
- **Replace the admin API key** in zsazsa and misp-scraper with dedicated, least-privilege users (see [First run](#first-run)).
- **Enable two-factor authentication** in MISP, or connect it to your identity provider (OIDC/LDAP, see `misp-docker/README.md`).
- **Distribution**: misp-scraper is configured to create events for your organisation only (`misp_distribution = 0`). Raise it deliberately if you sync with other MISP instances, and consider MISP-Guard (`COMPOSE_PROFILES=misp-guard`) when you do.
- **Backups** of the database and volumes, stored encrypted (see [Backup and restore](#backup-and-restore)).
- **Log rotation**: limit Docker's JSON logs host-wide in `/etc/docker/daemon.json` (`"log-opts": {"max-size": "10m", "max-file": "3"}`), and rotate `misp-docker/logs/` and the zsazsa/misp-scraper log files with logrotate.
- **Mail**: configure the `SMARTHOST_*` settings in `misp-docker/.env` to have MISP send notifications and password resets. Set `SMARTHOST_PORT` explicitly (an empty value breaks the relay configuration). With authentication, `SMARTHOST_ALIASES` (the relay's hostname or address, or `*`) must be set too, or the user and password are not used; `init.sh` sets it to `SMARTHOST_ADDRESS` when it is empty. The mail container (exim) only sends the password when the relay offers STARTTLS; for a relay without TLS on a trusted network (for example on the Docker host itself), add `SMARTHOST_ALLOW_PLAINTEXT_AUTH=true` to `misp-docker/.env`. Run `bash scripts/init.sh` and `docker compose up -d` after changing these. Test it with `docker compose exec mail sh -c 'printf "Subject: MISP test\n\nTest\n" | exim -f <MISP.email> <your address>'` and check `docker compose exec mail tail /var/log/exim4/mainlog`.
- **Resources**: tune `INNODB_BUFFER_POOL_SIZE` and the `PHP_*` settings in `misp-docker/.env` to the host's memory.

## Credits and licenses

The files of this repository outside the three upstream folders (`deploy/`, `scripts/`, this README and the other top-level files) are Copyright (C) 2026 Palmans IT Solutions and licensed under the **GNU Affero General Public License v3.0**, see [LICENSE](LICENSE).

This setup is based on the *misp-zsazsa* example from the Kraven Security livestream "MISP from scratch": <https://github.com/kraven-security/livestreams/tree/main/misp-from-scratch/misp-zsazsa>.

The bundled software belongs to its authors and keeps its own license:

- [MISP/misp-docker](https://github.com/MISP/misp-docker) — GNU GPL v3 (`misp-docker/LICENSE`)
- [cudeso/misp-scraper](https://github.com/cudeso/misp-scraper) — GNU AGPL v3 (`misp-scraper/LICENSE`)
- [zsazsa-project/zsazsa](https://github.com/zsazsa-project/zsazsa) — GNU AGPL v3 (`zsazsa/LICENSE`); its Docker setup credits Chris Horsley and elhoim
- [MISP](https://github.com/MISP/MISP) — GNU AGPL v3
