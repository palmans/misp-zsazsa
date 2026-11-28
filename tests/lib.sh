# Shared by tests/check.sh and tests/e2e.sh; sourced, not run.
# The variables are used by the scripts that source this file.
# shellcheck shell=bash disable=SC2034

TESTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$TESTS/.." && pwd)"

PASSED=0
FAILED=0
FAILURES=()
SECTION=""

if [[ -t 1 || -n "${GITHUB_ACTIONS:-}" ]]; then
    B=$'\033[1m' RED=$'\033[31m' GREEN=$'\033[32m' YELLOW=$'\033[33m' OFF=$'\033[0m'
else
    B="" RED="" GREEN="" YELLOW="" OFF=""
fi

section() {
    SECTION="$*"
    printf '\n%s== %s%s\n' "$B" "$*" "$OFF"
}

info() { printf '  %s..%s   %s\n' "$B" "$OFF" "$*"; }
pass() {
    PASSED=$((PASSED + 1))
    printf '  %sok%s   %s\n' "$GREEN" "$OFF" "$*"
}
skip() { printf '  %sskip%s %s\n' "$YELLOW" "$OFF" "$*"; }

# fail DESCRIPTION [DETAIL...]: the details are printed indented below it.
fail() {
    local what=$1
    shift
    FAILED=$((FAILED + 1))
    FAILURES+=("$SECTION: $what")
    printf '  %sFAIL%s %s\n' "$RED" "$OFF" "$what"
    local detail
    for detail in "$@"; do
        [[ -n "$detail" ]] && sed 's/^/       /' <<< "$detail"
    done
    if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
        # One line: an annotation ends at the first newline.
        printf '::error title=%s::%s\n' "${SECTION//[:,]/ }" "$what"
    fi
    return 0
}

# check DESCRIPTION COMMAND...: passes when the command succeeds, and shows
# the end of its output when it does not.
check() {
    local what=$1 out
    shift
    if out=$("$@" 2>&1); then
        pass "$what"
    else
        fail "$what" "$(tail -n 25 <<< "$out")"
    fi
}

# expect_eq DESCRIPTION EXPECTED ACTUAL
expect_eq() {
    if [[ "$2" == "$3" ]]; then
        pass "$1"
    else
        fail "$1" "expected: $2" "actual:   $3"
    fi
}

# expect_match DESCRIPTION REGEX TEXT
expect_match() {
    if [[ "$3" =~ $2 ]]; then
        pass "$1"
    else
        fail "$1" "expected to match: $2" "actual: $(tail -c 2000 <<< "$3")"
    fi
}

# py_checks SCRIPT|- ARG...: runs a Python script (- reads it from standard
# input) that prints "PASS<tab>what" or "FAIL<tab>what<tab>detail"
# lines, and counts them.
py_checks() {
    local out line status what detail
    if ! out=$(python3 "$@" 2>&1); then
        fail "python check crashed" "$(tail -n 25 <<< "$out")"
        return
    fi
    while IFS= read -r line; do
        IFS=$'\t' read -r status what detail <<< "$line"
        case "$status" in
            PASS) pass "$what" ;;
            FAIL) fail "$what" "${detail//\\n/$'\n'}" ;;
            *) [[ -n "$line" ]] && info "$line" ;;
        esac
    done <<< "$out"
}

# Prints the totals, adds them to the job summary on GitHub and exits 1 when
# something failed.
finish() {
    local title=$1 line
    printf '\n%s%s: %d passed, %d failed%s\n' "$B" "$title" "$PASSED" "$FAILED" "$OFF"
    for line in "${FAILURES[@]}"; do
        printf '  %sFAIL%s %s\n' "$RED" "$OFF" "$line"
    done
    if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
        {
            if (( FAILED )); then
                echo "### ❌ $title: $FAILED failed, $PASSED passed"
                echo
                for line in "${FAILURES[@]}"; do echo "- $line"; done
            else
                echo "### ✅ $title: all $PASSED checks passed"
            fi
            echo
        } >> "$GITHUB_STEP_SUMMARY"
    fi
    (( FAILED == 0 ))
}

# Copies the files git knows of (tracked, and new files it does not ignore) to
# DIR, without the runtime files (.env, volumes, ...) a checkout may have.
copy_repo() {
    local dir=$1
    mkdir -p "$dir"
    (
        cd "$REPO" &&
            git -c safe.directory='*' ls-files -z --cached --others --exclude-standard |
            while IFS= read -r -d '' f; do [[ -e "$f" || -L "$f" ]] && printf '%s\0' "$f"; done |
            tar --null -T - -cf -
    ) | tar -xf - -C "$dir"
}

# Value of the active KEY= line in a .env file, without quotes (as scripts/lib.sh).
env_value() {
    local v
    v=$(grep -E "^$2=" "$1" 2> /dev/null | tail -n 1 | cut -d= -f2-) || true
    v="${v%\"}"
    printf '%s' "${v#\"}"
}

# Value of a top-level assignment in a Python file, as Python's repr.
py_value() {
    python3 - "$1" "$2" << 'PY'
import ast, sys
tree = ast.parse(open(sys.argv[1]).read())
for node in tree.body:
    if isinstance(node, ast.Assign) and any(isinstance(t, ast.Name) and t.id == sys.argv[2] for t in node.targets):
        try:
            print(repr(ast.literal_eval(node.value)))
        except ValueError:
            print(ast.unparse(node.value))
        break
else:
    print("<missing>")
PY
}
