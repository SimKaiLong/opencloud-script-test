#!/usr/bin/env bash
# Prepare a GitHub-hosted Ubuntu runner as an Incus host for community-scripts.
# Run as root.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

echo "::group::Install Incus, expect, jq"
# Ubuntu's own incus (6.0.0) rejects `-f csv,noheader`, which the engine uses
# to list storage pools. Use the upstream (Zabbly) stable build instead.
mkdir -p /etc/apt/keyrings
curl -fsSL https://pkgs.zabbly.com/key.asc -o /etc/apt/keyrings/zabbly.asc
cat >/etc/apt/sources.list.d/zabbly-incus-stable.sources <<EOF
Enabled: yes
Types: deb
URIs: https://pkgs.zabbly.com/incus/stable
Suites: $(. /etc/os-release && echo "$VERSION_CODENAME")
Components: main
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/zabbly.asc
EOF
apt-get update -qq
apt-get install -y -qq incus expect jq >/dev/null
incus admin init --auto
incus version
# Fail here rather than deep inside the ct script.
pools="$(incus storage list -f csv,noheader | wc -l)"
[[ "$pools" -ge 1 ]] || { echo "::error::Incus reports no storage pools"; exit 1; }
incus storage list
echo "::endgroup::"

echo "::group::Networking"
# Docker on hosted runners sets the FORWARD policy to DROP, which silently
# breaks outbound traffic from Incus containers.
iptables -P FORWARD ACCEPT || true
iptables -I DOCKER-USER -j ACCEPT 2>/dev/null || true
ip6tables -P FORWARD ACCEPT 2>/dev/null || true
incus network show incusbr0
echo "::endgroup::"

# check_for_gh_release / fetch_and_deploy_gh_release run inside the container,
# and hosted runners share egress IPs (60 unauthenticated API calls/h).
# environment.* on the profile is injected into every `incus exec`.
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  incus profile set default environment.GITHUB_TOKEN "$GITHUB_TOKEN"
fi

# Answer the diagnostics question up front and keep CI out of install stats.
mkdir -p /usr/local/community-scripts
echo "DIAGNOSTICS=no" >/usr/local/community-scripts/diagnostics

echo "Host ready"
