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
}
EOF
