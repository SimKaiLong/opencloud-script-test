#!/usr/bin/env bash
# Create an OpenCloud container on this Incus host with the real ct/ script.
# Run as root.
#
# usage: run-install.sh <hostname> <scripts-base-url>
#   scripts-base-url: raw URL of a ProxmoxVE tree, e.g.
#   https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"

export var_hostname="${1:?hostname}"
export COMMUNITY_SCRIPTS_URL="${2:?scripts base url}"
export PHS_SILENT=1 mode=default DIAGNOSTICS=no TERM=xterm

curl -fsSL "${COMMUNITY_SCRIPTS_URL}/ct/opencloud.sh" -o /tmp/ct-opencloud.sh
expect "${here}/install-ct.exp" /tmp/ct-opencloud.sh
