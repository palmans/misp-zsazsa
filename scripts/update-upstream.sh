#!/usr/bin/env bash
# Replaces misp-docker/, misp-scraper/ and zsazsa/ with the latest upstream
# version, keeps this deployment's runtime files and data in them, and records
# the commits in UPSTREAM.md. Review the changes (git diff) before you rebuild.
#
#   bash scripts/update-upstream.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# folder|repository|branch|paths kept (relative to the folder)
COMPONENTS=(
    "misp-docker|https://github.com/MISP/misp-docker.git|master|.env ssl configs files gnupg logs custom env.hcl docker-compose.override.yml exim-macros"
    "misp-scraper|https://github.com/cudeso/misp-scraper.git|main|scraper.py docker/.env docker/config"
    "zsazsa|https://github.com/zsazsa-project/zsazsa.git|main|docker/.env docker/volumes"
)

command -v git > /dev/null || { echo "git is required." >&2; exit 1; }

WORK="$(mktemp -d)"
# On the same filesystem as the folders, so moving data out and back is instant.
STASH="$ROOT/.upstream-stash"
trap 'rm -rf "$WORK"; [[ -d "$STASH" ]] && echo "Interrupted: kept files are in $STASH" >&2' EXIT
[[ -e "$STASH" ]] && { echo "$STASH exists: a previous update was interrupted. Restore its files first." >&2; exit 1; }

ROWS=""
for component in "${COMPONENTS[@]}"; do
    IFS='|' read -r dir repo branch keep <<< "$component"
    echo "==> $dir"
    git clone -q --depth 1 --branch "$branch" "$repo" "$WORK/$dir"
    sha="$(git -C "$WORK/$dir" rev-parse HEAD)"
    date="$(git -C "$WORK/$dir" log -1 --format=%cs)"

    mkdir -p "$STASH/$dir"
    for path in $keep; do
        if [[ -e "$ROOT/$dir/$path" ]]; then
            mkdir -p "$(dirname "$STASH/$dir/$path")"
            mv "$ROOT/$dir/$path" "$STASH/$dir/$path"
        fi
    done

    rm -rf "${ROOT:?}/$dir"
    mkdir -p "$ROOT/$dir"
    git -C "$WORK/$dir" -c core.autocrlf=false archive --format=tar HEAD | tar -x -C "$ROOT/$dir"

    for path in $keep; do
        if [[ -e "$STASH/$dir/$path" ]]; then
            mkdir -p "$(dirname "$ROOT/$dir/$path")"
            rm -rf "${ROOT:?}/$dir/$path"
            mv "$STASH/$dir/$path" "$ROOT/$dir/$path"
        fi
    done
    rm -rf "$STASH/$dir"

    ROWS+="| \`$dir/\` | ${repo%.git} | \`${sha:0:12}\` | $date |"$'\n'
    echo "    ${sha:0:12} ($date)"
done
rmdir "$STASH"

cat > "$ROOT/UPSTREAM.md" << EOF
# Upstream sources

These folders are unmodified copies of their upstream repositories, written by
\`scripts/update-upstream.sh\`. Changes made in them are lost on the next
update: deployment-specific changes belong in \`deploy/\`.

| Folder | Repository | Commit | Date |
|---|---|---|---|
$ROWS
EOF

cat << 'EOF'

Updated. Next:
  git diff --stat                     # review what changed upstream
  bash scripts/init.sh                # applies new image tags to misp-docker/.env
  cd misp-docker && docker compose pull && docker compose up -d
  cd ../zsazsa/docker && docker compose build --pull && docker compose up -d
Then open zsazsa's Settings > System and run any new migration it lists.
EOF
