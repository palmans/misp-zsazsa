"""Runs inside misp-core; scripts/post-install.sh pipes it in.

Enables the taxonomies zsazsa and misp-scraper tag with, and creates a MISP
user with an API key of its own for each of them, so they stop using the
administrator's key. What already exists is left alone.

Environment (set by scripts/post-install.sh; ADMIN_KEY comes from misp-core):
    MISP_URL    MISP as seen from misp-core, e.g. https://misp-nginx:8443
    TAXONOMIES  namespaces, space separated; namespace=tag,tag enables only
                those tags of it and hides the others that exist
    USERS       name=email=allowed-ip-range, space separated (range may be empty)
    ROLE        role of the new users
    NEW_KEYS    "1": also add a key to users that already exist

Prints "KEY <name> <authkey>" for every key it creates.
"""

import json
import os
import re
import secrets
import ssl
import string
import sys
import time
import urllib.error
import urllib.request

URL = os.environ["MISP_URL"].rstrip("/")
ADMIN_KEY = os.environ["ADMIN_KEY"]
# misp-nginx has a self-signed certificate.
CONTEXT = ssl._create_unverified_context()


def call(path, data=None, fatal=True):
    request = urllib.request.Request(
        URL + path,
        data=None if data is None else json.dumps(data).encode(),
        method="GET" if data is None else "POST",
        headers={"Authorization": ADMIN_KEY, "Accept": "application/json",
                 "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(request, context=CONTEXT, timeout=300) as response:
            body = response.read()
    except urllib.error.HTTPError as error:
        detail = error.read()[:2000].decode(errors="replace")
        title = re.search(r"<title>(.*?)</title>", detail, re.S)
        message = f"{request.method} {path}: HTTP {error.code} {title.group(1).strip() if title else detail[:500]}"
        if fatal:
            sys.exit(message)
        print(f"warning: {message}")
        return None
    try:
        return json.loads(body) if body else None
    except ValueError:
        return body.decode(errors="replace")


def wait_for_misp(seconds=300):
    """misp-core answers only once its start is done; nginx says 502 until then."""
    deadline = time.monotonic() + seconds
    while True:
        try:
            request = urllib.request.Request(URL + "/servers/getVersion",
                                             headers={"Authorization": ADMIN_KEY, "Accept": "application/json"})
            with urllib.request.urlopen(request, context=CONTEXT, timeout=30):
                return
        except (urllib.error.URLError, OSError) as error:
            if time.monotonic() > deadline:
                sys.exit(f"MISP did not answer within {seconds}s ({error}). Is misp-core healthy? "
                         "If so, restart misp-nginx: docker compose restart misp-nginx")
            print(f"waiting for MISP ({error})", flush=True)
            time.sleep(10)


def unwrap(item, model):
    return item.get(model, item) if isinstance(item, dict) else item


def password():
    # Never used to log in; long enough for any password policy.
    alphabet = string.ascii_letters + string.digits
    return "Aa1-" + "".join(secrets.choice(alphabet) for _ in range(40))


def taxonomies(specs):
    # namespace -> the tags to enable, or None for all of them
    wanted = {}
    for spec in specs:
        namespace, _, tags = spec.partition("=")
        wanted[namespace] = [t for t in tags.split(",") if t] or None

    found = set()
    for item in call("/taxonomies/index") or []:
        taxonomy = unwrap(item, "Taxonomy")
        namespace = taxonomy.get("namespace")
        if namespace not in wanted:
            continue
        found.add(namespace)
        taxonomy_id = taxonomy["id"]
        if not taxonomy.get("enabled"):
            call(f"/taxonomies/enable/{taxonomy_id}", {})
            print(f"taxonomy {namespace}: enabled")
        else:
            print(f"taxonomy {namespace}: already enabled")

        tags = wanted[namespace]
        if tags is None:
            # Adds the tags that are missing; harmless when all exist.
            call(f"/taxonomies/addTag/{taxonomy_id}", {})
            continue
        call("/taxonomies/addTag", {"Tag": {"taxonomy_id": taxonomy_id, "nameList": json.dumps(tags)}})
        print(f"taxonomy {namespace}: tags {', '.join(tags)}")
        hide_other_tags(taxonomy_id, namespace, tags)

    for namespace in sorted(set(wanted) - found):
        print(f"taxonomy {namespace}: not found in this MISP, skipped")


def hide_other_tags(taxonomy_id, namespace, keep):
    """Hides the tags of the taxonomy that exist but are not in keep."""
    view = call(f"/taxonomies/view/{taxonomy_id}", fatal=False)
    entries = view.get("entries", []) if isinstance(view, dict) else []
    others = [e["tag"] for e in entries
              if isinstance(e, dict) and e.get("existing_tag") and e.get("tag") not in keep]
    if not others:
        return
    call("/taxonomies/hideTag", {"Tag": {"taxonomy_id": taxonomy_id, "nameList": json.dumps(others)}},
         fatal=False)
    print(f"taxonomy {namespace}: hid {', '.join(others)}")


def users(specs, role_name, new_keys):
    roles = {unwrap(r, "Role")["name"]: unwrap(r, "Role")["id"] for r in call("/roles/index") or []}
    if role_name not in roles:
        sys.exit(f"role {role_name!r} not found; roles: {', '.join(sorted(roles))}")
    org_id = unwrap(call("/users/view/me"), "User")["org_id"]
    existing = {unwrap(u, "User")["email"].lower(): unwrap(u, "User")["id"]
                for u in call("/admin/users/index") or []}

    for spec in specs:
        name, email, allowed = (spec.split("=") + ["", ""])[:3]
        user_id = existing.get(email.lower())
        if user_id:
            print(f"user {email}: exists (id {user_id})")
            if not new_keys:
                continue
        else:
            created = call("/admin/users/add", {"User": {
                "email": email, "org_id": org_id, "role_id": roles[role_name],
                "password": password(), "change_pw": 0, "termsaccepted": 1,
                "autoalert": 0, "contactalert": 0, "notify": 0,
            }})
            user_id = unwrap(created, "User")["id"]
            print(f"user {email}: created (id {user_id}, role {role_name})")

        key = {"comment": f"{name} (scripts/post-install.sh)"}
        if allowed:
            key["allowed_ips"] = [allowed]
        authkey = unwrap(call(f"/auth_keys/add/{user_id}", key), "AuthKey")
        print(f"user {email}: API key added" + (f", allowed from {allowed}" if allowed else ""))
        print(f"KEY {name} {authkey['authkey_raw']}")


wait_for_misp()
taxonomies(os.environ.get("TAXONOMIES", "").split())
users(os.environ.get("USERS", "").split(), os.environ.get("ROLE", "Org Admin"),
      os.environ.get("NEW_KEYS") == "1")
