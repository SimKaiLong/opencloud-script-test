#!/usr/bin/env bash
# Simulate a search service that is not up yet when the update starts the
# reindex. Run as root.
#
# usage: fault.sh inject   — before the update: start OpenCloud without search
#        fault.sh clear    — after the update: prove the reindex unit kept
#                            retrying, then bring search back
set -uo pipefail
source "$(dirname "$0")/lib.sh"
env_file=/etc/opencloud/opencloud.env

retried() {
  local n
  n="$(ct systemctl show opencloud-reindex -p NRestarts --value 2>/dev/null)"
  echo "opencloud-reindex NRestarts=${n:-none}"
  [[ "${n:-0}" -ge 1 ]]
}
# While waiting to retry the unit is "activating/auto-restart"; is-active exits
# non-zero for that, so read the state instead.
unit_waiting() {
  local state
  state="$(ct systemctl show opencloud-reindex -p ActiveState -p SubState --value | paste -sd/)"
  echo "opencloud-reindex ${state}"
  [[ "$state" == activating/* || "$state" == active/* ]]
}

case "${1:?inject|clear}" in
inject)
  ct bash -c "echo 'OC_EXCLUDE_RUN_SERVICES=search' >>${env_file}"
  echo "search service excluded until 'fault.sh clear'"
  ;;
clear)
  summary_header "Search service unavailable during update"
  check "reindex unit retried while search was down" poll 120 retried
  check "reindex unit still waiting, not given up" unit_waiting
  ct sed -i '/^OC_EXCLUDE_RUN_SERVICES=search$/d' "$env_file"
  ct systemctl restart opencloud
  echo "search service restored"
  finish_checks
  ;;
esac
