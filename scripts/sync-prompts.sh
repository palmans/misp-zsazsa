#!/usr/bin/env bash
# zsazsa keeps its AI prompts in zsazsa/docker/volumes/prompts, so that edits on
# its Prompts tab survive updates. A release that changes a shipped prompt
# therefore does not reach that copy; zsazsa's CHANGELOG says when to take one.
#
# Lists the prompts that differ from the ones the running image ships. With
# --apply it replaces them, all or the ones named, and keeps the old copy in
# zsazsa/docker/volumes/data/prompts-backup/.
#
#   bash scripts/sync-prompts.sh [--apply] [prompt.md ...]
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

APPLY=0
NAMES=()
for arg in "$@"; do
    case "$arg" in
        --apply) APPLY=1 ;;
        -*) die "Unknown option $arg. Usage: bash scripts/sync-prompts.sh [--apply] [prompt.md ...]" ;;
        *) NAMES+=("$arg") ;;
    esac
done

(cd "$ZSAZSA_DIR" && docker compose exec -T -e APPLY="$APPLY" webapp python - "${NAMES[@]}") << 'PY'
import os
import shutil
import sys
import time
from pathlib import Path

shipped = Path("/opt/zsazsa/zsazsaprompts")
live = Path("/app/zsazsaprompts")
backup = Path("/app/data/prompts-backup") / time.strftime("%Y%m%d-%H%M%S")
only = set(sys.argv[1:])
apply = os.environ.get("APPLY") == "1"

differ = []
for src in sorted(p for p in shipped.iterdir() if p.is_file()):
    if only and src.name not in only:
        continue
    dst = live / src.name
    if not dst.exists() or dst.read_bytes() == src.read_bytes():
        continue
    differ.append(src.name)
    if apply:
        backup.mkdir(parents=True, exist_ok=True)
        shutil.copy2(dst, backup / src.name)
        shutil.copy2(src, dst)
        print(f"replaced {src.name}")
    else:
        print(f"differs  {src.name}")

if not differ:
    print("All prompts match the versions this zsazsa ships.")
elif apply:
    print(f"Old copies: zsazsa/docker/volumes/data/prompts-backup/{backup.name}/")
else:
    print("Take the shipped versions with --apply, all or the ones named. Prompts you edited")
    print("on zsazsa's Prompts tab differ too: name only the ones the CHANGELOG mentions.")
PY
