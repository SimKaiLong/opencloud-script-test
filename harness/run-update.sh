#!/usr/bin/env bash
# Run the ct/ script's update path inside the container, the way the
# one-liner does on Proxmox. Output goes to $STATE_DIR/<label>.log.
# Run as root.
#
# usage: run-update.sh <scripts-base-url> <label>
set -euo pipefail
source "$(dirname "$0")/lib.sh"
url="${1:?scripts base url}"
label="${2:?label}"

script="$(curl -fsSL "${url}/ct/opencloud.sh")"
# LXC_PLATFORM=container: take the Proxmox container path (ui/menu.func
# start), not the Incus wrapper, so this is what PVE users execute.
set -o pipefail
ct env LXC_PLATFORM=container PHS_SILENT=1 TERM=xterm bash -c "$script" 2>&1 |
  sed -u 's/\x1b\[[0-9;?]*[a-zA-Z]//g' | tee "${STATE_DIR}/${label}.log"
