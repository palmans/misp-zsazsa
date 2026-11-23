#!/usr/bin/env sh
# -*- coding: utf-8 -*-
# Serves zsazsa under /zsazsa/ on MISP's own address, so the browser sends
# MISP's session cookie along and zsazsa's single sign-on works.
#
# Mounted into misp-nginx's /docker-entrypoint.d/ by
# deploy/misp-docker.override.yml. It runs after 03-conditional-headers.sh,
# which empties the file below on every start, and adds the locations to it:
# that file is included inside MISP's server block.

set -eu

CONF="${NGINX_INCLUDE_DIR}/conditional-headers.conf"

cat >> "$CONF" <<'EOF'

# zsazsa CTI application
location = /zsazsa {
    absolute_redirect off;
    return 301 /zsazsa/;
}
location ^~ /zsazsa/ {
    # Looked up per request, so MISP still starts while zsazsa is down.
    resolver 127.0.0.11 valid=30s ipv6=off;
    set $zsazsa http://zsazsa:5000;
    rewrite ^/zsazsa/(.*)$ /$1 break;
    proxy_pass $zsazsa;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Prefix /zsazsa;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_read_timeout 300s;
    # Without a MISP session zsazsa sends the browser to MISP's login page,
    # which forgets where it came from. /zsazsa-login remembers the page.
    proxy_redirect ~^https?://[^/]+/users/login$ /zsazsa-login$request_uri;
}

# Remembers the zsazsa page for after the login, in a cookie that only MISP's
# after-login route gets, then shows MISP's login page.
location ^~ /zsazsa-login/ {
    absolute_redirect off;
    set $zsazsa_cookie "";
    if ($request_uri ~ "^/zsazsa-login(/zsazsa/[A-Za-z0-9/._~%?=&+-]*)$") {
        set $zsazsa_cookie "zsazsa_return=$1; Path=/users/routeafterlogin; Max-Age=900; Secure; HttpOnly; SameSite=Lax";
    }
    # Only for a page opened in the browser, not for a background fetch of an
    # open zsazsa tab whose session ran out.
    if ($http_sec_fetch_mode !~ "^(navigate)?$") {
        set $zsazsa_cookie "";
    }
    # An empty value adds no header.
    add_header Set-Cookie $zsazsa_cookie always;
    return 302 /users/login;
}

# Every MISP login ends on /users/routeafterlogin. With the cookie above it
# goes to the zsazsa page instead; without it, MISP decides as usual.
set $zsazsa_after_login "$uri|$cookie_zsazsa_return";
if ($zsazsa_after_login ~ "^/users/routeafterlogin\|(/zsazsa/.*)$") {
    set $zsazsa_return $1;
    rewrite ^ /zsazsa-return last;
}
location = /zsazsa-return {
    internal;
    absolute_redirect off;
    add_header Set-Cookie "zsazsa_return=; Path=/users/routeafterlogin; Max-Age=0; Secure; HttpOnly; SameSite=Lax" always;
    return 302 $zsazsa_return;
}
EOF
