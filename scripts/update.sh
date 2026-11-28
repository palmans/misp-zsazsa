#!/usr/bin/env bash
# Updates this deployment on the Docker host to what the repository has now,
# for example after merging the pull request of the "Upstream update" workflow:
#
#   1. git pull (fast-forward only), after showing what comes in: the commits,
#      new MISP image versions and the lines added to zsazsa's CHANGELOG
#   2. scripts/init.sh: applies the new MISP image tags to misp-docker/.env
#   3. misp-docker: docker compose pull && up -d, until healthy
#   4. zsazsa: docker compose build --pull && up -d, until healthy
#   5. scripts/sync-prompts.sh: lists the prompts that differ from the shipped ones
#
# Then it reminds you of what stays manual: zsazsa's "Upgrading" notes, the
# prompts to take over and zsazsa's migrations. It asks before it changes
# anything (unless --yes, or without a terminal). Safe to run again, e.g. after
# a step failed: steps that have nothing to do do nothing.
#
#   sudo bash scripts/update.sh [--yes] [--skip-git] [--no-image-pull]
#
#   --yes            do not ask before updating
#   --skip-git       leave the checkout as it is (you updated it yourself, for
#                    example with scripts/update-upstream.sh)
#   --no-image-pull  use the images on this host: no "docker compose pull", and
#                    zsazsa is built without --pull (no access to the registries)
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

YES=0
GIT=1
IMAGE_PULL=1
for arg in "$@"; do
    case "$arg" in
        --yes | -y) YES=1 ;;
        --skip-git) GIT=0 ;;
        --no-image-pull) IMAGE_PULL=0 ;;
        *) die "Unknown option $arg. Usage: sudo bash scripts/update.sh [--yes] [--skip-git] [--no-image-pull]" ;;
    esac
done

[[ -f "$MISP_ENV" && -f "$ZSAZSA_ENV" ]] || die "Not installed yet: see Installation in README.md."
command -v docker > /dev/null || die "Run this on the Docker host."
is_root || warn "Not root: init.sh cannot give the volumes to uid 1000 (see README.md)."

git_() { git -C "$ROOT" "$@"; }
OLD=$(git_ rev-parse HEAD)

# What changes between two commits: MISP image versions and zsazsa's CHANGELOG.
changes() {
    local tags changelog
    tags=$(git_ diff -U0 "$1" "$2" -- misp-docker/template.env | grep -E '^[-+](CORE|MODULES|GUARD)_TAG=' || true)
    if [[ -n "$tags" ]]; then
        echo
        echo "MISP image versions (read MISP's release notes across minor versions):"
        sed 's/^/    /' <<< "$tags"
    fi
    changelog=$(git_ diff -U0 "$1" "$2" -- zsazsa/CHANGELOG.md | grep -E '^\+' | grep -vE '^\+\+\+' | cut -c2- || true)
    if [[ -n "$changelog" ]]; then
        echo
        echo "zsazsa CHANGELOG, added lines (mind the \"Upgrading\" notes):"
        sed 's/^/    /' <<< "$changelog"
    fi
}

# --- 1. git pull -------------------------------------------------------------

if (( GIT )); then
    info "git: what comes in"
    # An init.sh before this one made lib.sh executable, which git counts as a change.
    chmod -x "$ROOT/scripts/lib.sh"
    # Files git tracks that changed here would make the pull fail halfway.
    local_changes=$(git_ status --porcelain --untracked-files=no)
    [[ -z "$local_changes" ]] || die "Files git tracks were changed on this host; commit, stash or undo them first:
$local_changes"
    upstream=$(git_ rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2> /dev/null) ||
        die "The branch $(git_ branch --show-current) follows no remote branch; update the checkout yourself and use --skip-git."
    git_ fetch --quiet
    incoming=$(git_ log --oneline --no-decorate "HEAD..$upstream")
    if [[ -z "$incoming" ]]; then
        echo "    nothing new on $upstream; the stacks are brought up to date anyway"
    else
        git_ merge-base --is-ancestor HEAD "$upstream" ||
            die "This checkout has commits $upstream does not have: it cannot fast-forward. Sort that out with git first."
        echo "    $(wc -l <<< "$incoming") commit(s) from $upstream:"
        sed 's/^/      /' <<< "$incoming"
        changes HEAD "$upstream"
    fi
    if (( ! YES )) && [[ -t 0 ]]; then
        echo
        read -r -p "Update now? [y/N] " answer
        [[ "$answer" =~ ^[YyJj] ]] || { echo "Nothing changed."; exit 0; }
    fi
    if [[ -n "$incoming" ]]; then
        git_ merge --ff-only --quiet "$upstream"
        echo "    updated to $(git_ log -1 --format='%h %s')"
        # The rest as the version just pulled does it.
        args=(--skip-git --yes)
        (( IMAGE_PULL )) || args+=(--no-image-pull)
        UPDATE_FROM="$OLD" exec bash "$ROOT/scripts/update.sh" "${args[@]}"
    fi
fi
# Set by the update.sh that pulled this version.
OLD=${UPDATE_FROM:-$OLD}
NEW=$(git_ rev-parse HEAD)

# --- 2.-4. Configuration and containers ------------------------------------------

info "scripts/init.sh"
bash "$ROOT/scripts/init.sh" | sed 's/^/    /'

MISP() { (cd "$MISP_DIR" && docker compose "$@"); }
ZSAZSA() { (cd "$ZSAZSA_DIR" && docker compose "$@"); }

info "MISP: $(get_env "$MISP_ENV" CORE_RUNNING_TAG), modules $(get_env "$MISP_ENV" MODULES_RUNNING_TAG)"
(( IMAGE_PULL )) && MISP pull --quiet
# A new MISP version updates its database at the start: that can take minutes.
MISP up -d --wait --wait-timeout 1800 ||
    die "MISP did not become healthy. See: cd misp-docker && docker compose ps; docker compose logs misp-core"

info "zsazsa and misp-scraper: build and start"
if (( IMAGE_PULL )); then ZSAZSA build --pull; else ZSAZSA build; fi
ZSAZSA up -d --wait --wait-timeout 600 ||
    die "zsazsa did not start. See: cd zsazsa/docker && docker compose ps; docker compose logs"

# --- 5. Prompts --------------------------------------------------------------------

info "Prompts that differ from the ones this zsazsa ships"
bash "$ROOT/scripts/sync-prompts.sh" | sed 's/^/    /'

# --- What stays manual ---------------------------------------------------------------

info "Done: $(git_ log -1 --format='%h %s')"
if [[ "$OLD" != "$NEW" ]]; then
    changes "$OLD" "$NEW"
fi
cat << 'EOF'

Still to do by hand:
  - Read the "Upgrading" notes in zsazsa/CHANGELOG.md, for anything beyond a rebuild.
  - Take changed prompts the CHANGELOG names: bash scripts/sync-prompts.sh --apply <prompt.md> ...
    (prompts you edited on zsazsa's Prompts tab are listed above too; leave those)
  - Run any new migration zsazsa lists under Settings > System > Migration (dry run first).
  - Old images take disk space: docker image prune
EOF
