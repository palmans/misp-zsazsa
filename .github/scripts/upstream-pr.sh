#!/usr/bin/env bash
# Describes what scripts/update-upstream.sh changed in the working tree,
# compared with HEAD, for the pull request of the upstream-update workflow.
#
#   bash .github/scripts/upstream-pr.sh title [failed-patches-file]
#   bash .github/scripts/upstream-pr.sh body  [failed-patches-file]
set -euo pipefail

MODE=${1:?usage: upstream-pr.sh title|body [failed-patches-file]}
FAILED_FILE=${2:-}
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

# "folder repository commit date" per row of the UPSTREAM.md table.
rows() { awk -F'|' '/^\| `/ { for (i = 2; i <= 5; i++) { gsub(/[` ]/, "", $i) } print $2, $3, $4, $5 }'; }

declare -A OLD
while read -r dir _ sha _; do OLD[$dir]=$sha; done < <(git show HEAD:UPSTREAM.md | rows)

FAILED=()
if [[ -n "$FAILED_FILE" && -s "$FAILED_FILE" ]]; then
    mapfile -t FAILED < "$FAILED_FILE"
fi

if [[ "$MODE" == title ]]; then
    parts=()
    while read -r dir _ sha _; do
        [[ "${OLD[$dir]:-}" != "$sha" ]] && parts+=("${dir%/} ${sha:0:7}")
    done < <(rows < UPSTREAM.md)
    title="Upstream update"
    (( ${#parts[@]} )) && title+=": $(IFS=,; echo "${parts[*]}" | sed 's/,/, /g')"
    (( ${#FAILED[@]} )) && title="⚠️ $title (patch failed)"
    echo "$title"
    exit 0
fi

[[ "$MODE" == body ]] || { echo "unknown mode: $MODE" >&2; exit 1; }

echo "Automatic update by \`scripts/update-upstream.sh\` (workflow *Upstream update*)."
echo
echo "The workflow then installs this branch on a test runner, fresh and as an update of the base branch"
echo "(\`tests/check.sh\`, \`tests/e2e.sh\`): see the status *Upstream update / tests* before merging."
echo
echo "| Folder | Change | Upstream commits | Files |"
echo "|---|---|---|---|"
while read -r dir repo sha date; do
    old=${OLD[$dir]:-}
    files=$(git diff --name-only HEAD -- "$dir" | wc -l)
    if [[ "$old" == "$sha" ]]; then
        echo "| \`$dir\` | unchanged (\`$sha\`, $date) | | $files |"
    else
        echo "| \`$dir\` | \`${old:-?}\` → \`$sha\` ($date) | [compare]($repo/compare/$old...$sha) | $files |"
    fi
done < <(rows < UPSTREAM.md)
echo

if (( ${#FAILED[@]} )); then
    echo "## ⚠️ Patches that did not apply"
    echo
    echo "Upstream changed this code, or fixed the problem itself. The folder in this PR does **not** contain the fix:"
    echo "check upstream, then update or remove the patch and push it to this branch (or rerun the workflow)."
    echo
    printf -- '- `%s`\n' "${FAILED[@]}"
    echo
fi

tags=$(git diff -U0 HEAD -- misp-docker/template.env | grep -E '^[-+](CORE|MODULES|GUARD)_TAG=' || true)
if [[ -n "$tags" ]]; then
    echo "## MISP image versions"
    echo
    echo "Read the MISP release notes before an update across minor versions."
    echo
    echo '```diff'
    echo "$tags"
    echo '```'
    echo
fi

changelog=$(git diff -U0 HEAD -- zsazsa/CHANGELOG.md | grep -E '^\+' | grep -vE '^\+\+\+' | cut -c2- || true)
if [[ -n "$changelog" ]]; then
    echo "## zsazsa CHANGELOG (added lines)"
    echo
    echo "Pay attention to the **Upgrading** notes."
    echo
    echo "<details><summary>Show</summary>"
    echo
    echo "$changelog" | sed -n 1,200p
    (( $(echo "$changelog" | wc -l) > 200 )) && echo && echo "*(cut off after 200 lines, see the diff)*"
    echo
    echo "</details>"
    echo
fi

cat << 'EOF'
## After merging, on the Docker host

```bash
cd /opt/misp-zsazsa && sudo bash scripts/update.sh
```

It shows what comes in and asks first, then pulls, runs `init.sh` (new MISP image tags), pulls and starts MISP, builds and starts zsazsa and misp-scraper, and lists the prompts that differ. See *Updating* in `README.md` for the steps by hand.

- [ ] Read the "Upgrading" notes in `zsazsa/CHANGELOG.md`
- [ ] Take changed prompts: `bash scripts/sync-prompts.sh [--apply <prompt.md> ...]`
- [ ] Run any new migration zsazsa lists under *Settings → System → Migration*
EOF
