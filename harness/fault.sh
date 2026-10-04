#!/usr/bin/env bash
# Simulate a search service that is not available when the update starts the
# reindex. Run as root.
#
# usage: fault.sh inject        before the update: start OpenCloud without search
#        fault.sh restore-late  run in the background during the update: once the
#                               reindex unit has retried, bring search back
#        fault.sh check-late    after the update: the unit retried, the update waited
#                               and reported success
#        fault.sh check-never   after the update (search never came back): the update
#                               gave up with a retry command; run that command the way
#                               a user would
set -uo pipefail
source "$(dirname "$0")/lib.sh"
env_file=/etc/opencloud/opencloud.env
result="${STATE_DIR}/fault.result"

restarts() { ct systemctl show opencloud-reindex -p NRestarts --value 2>/dev/null; }
retried() { [[ "$(restarts)" -ge 1 ]] 2>/dev/null; }
restore_search() {
  ct sed -i '/^OC_EXCLUDE_RUN_SERVICES=search$/d' "$env_file"
  ct systemctl restart opencloud
}
search_listening() { ct bash -c "ss -ltn | grep -q ':9220 '"; }

case "${1:?mode}" in
inject)
  ct bash -c "echo 'OC_EXCLUDE_RUN_SERVICES=search' >>${env_file}"
  echo "search service excluded"
  ;;
restore-late)
  if poll 300 retried; then
    echo "retried NRestarts=$(restarts)" >"$result"
  else
    echo "no retry seen" >"$result"
  fi
  restore_search
  echo "search service restored ($(cat "$result"))"
  ;;
check-late)
  summary_header "Search service comes up late"
  check "reindex unit retried while search was down" grep -q '^retried' "$result"
  check "update waited and reported success" log_has update "Rebuilt search index"
  finish_checks
  ;;
check-never)
  summary_header "Search service never comes up"
  check "update gave up instead of hanging" log_has update "The rebuild did not complete"
  check "update printed a retry command" log_has update "Retry with: "
  check "update still finished" log_has update "Updated successfully"
  restore_search
  poll 120 search_listening
  cmd="$(sed -n 's/.*Retry with: //p' "${STATE_DIR}/update.log" | tail -1)"
  echo "running the printed retry command: ${cmd}"
  check "printed retry command starts the reindex" ct bash -c "$cmd"
  finish_checks
  ;;
esac
