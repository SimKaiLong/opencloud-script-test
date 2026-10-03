#!/usr/bin/env bash
# Put Caddy (internal CA) in front of the container for the fake *.oc.test
# names, make both sides trust it, and enable basic auth for API tests.
# Run as root after the install.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

name="$(ct_name)"
ct_ip="$(incus list "$name" -c 4 -f csv | awk '{print $1}' | head -1)"
bridge_ip="$(incus network get incusbr0 ipv4.address | cut -d/ -f1)"
echo "container ${name} at ${ct_ip}; bridge ${bridge_ip}"

if ! command -v caddy >/dev/null; then
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq caddy >/dev/null
fi
cat >/etc/caddy/Caddyfile <<EOF
{
  local_certs
}
cloud.oc.test {
  reverse_proxy ${ct_ip}:9200
}
collabora.oc.test {
  reverse_proxy ${ct_ip}:9980
}
wopi.oc.test {
  reverse_proxy ${ct_ip}:9300
}
EOF
systemctl restart caddy

root=/var/lib/caddy/.local/share/caddy/pki/authorities/local/root.crt
poll 60 test -s "$root"
cp "$root" "$CA_FILE"

# Runner side resolves the names to Caddy on localhost.
grep -q 'oc.test' /etc/hosts || echo "127.0.0.1 cloud.oc.test collabora.oc.test wopi.oc.test" >>/etc/hosts

# Container side: names → Caddy on the bridge, trust its CA.
incus file push "$CA_FILE" "${name}/usr/local/share/ca-certificates/oc-test-caddy.crt"
ct bash -c "grep -q oc.test /etc/hosts || echo '${bridge_ip} cloud.oc.test collabora.oc.test wopi.oc.test' >>/etc/hosts
  update-ca-certificates >/dev/null"

# Test-only settings: basic auth for curl, INFO logs for the sharing migration.
ct bash -c "grep -q '^PROXY_ENABLE_BASIC_AUTH=' /etc/opencloud/opencloud.env || cat >>/etc/opencloud/opencloud.env <<'EOF'

## oc-test harness only
PROXY_ENABLE_BASIC_AUTH=true
SHARING_LOG_LEVEL=info
EOF
  systemctl restart coolwsd opencloud
  sleep 5
  systemctl restart opencloud-wopi"

pw="$(admin_password)"
echo "::add-mask::${pw}"
printf '%s' "$pw" >"${STATE_DIR}/admin_pw"

ADMIN_PW="$pw"
poll 180 api GET /graph/v1.0/me -o /dev/null
echo "OpenCloud reachable at ${OC_URL} via Caddy, admin login works"
