#!/bin/bash
# Runs in misp-core at the end of every start, before PHP-FPM starts.
# Mounted as /custom/files/customize_misp.sh by deploy/misp-docker.override.yml.
# Settings here are re-applied on every start; keep them idempotent.
set -euo pipefail

CAKE="sudo -u www-data /var/www/MISP/app/Console/cake"

# TLS terminates at the reverse proxy: without this MISP considers the
# connection insecure (security audit), and does not mark session cookies Secure.
$CAKE Admin setSetting -q Security.force_https true

# PHP session hardening from MISP's security audit. The container is recreated
# from the image on updates, so php.ini is edited on every start.
set_php() {
    local ini=$1 key=$2 value=$3
    if grep -qE "^;?\s*${key//./\\.}\s*=" "$ini"; then
        sed -i -E "s/^;?\s*${key//./\\.}\s*=.*/$key = $value/" "$ini"
    else
        echo "$key = $value" >> "$ini"
    fi
}
# The CLI gets the same values, so cake's security audit agrees with the web server.
for ini in /etc/php/*/fpm/php.ini /etc/php/*/cli/php.ini; do
    set_php "$ini" session.use_strict_mode 1
    set_php "$ini" session.sid_bits_per_character 5
done

echo "customize_misp.sh | force_https and PHP session hardening applied"
