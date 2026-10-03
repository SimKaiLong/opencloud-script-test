#!/usr/bin/env bash
# Checks, grouped by phase. Each check is reported to the job summary; the
# script exits non-zero if any failed. Run as root.
#
# usage: verify.sh <baseline|fresh|update|migration|rerun> [expected-version]
set -uo pipefail
source "$(dirname "$0")/lib.sh"
ADMIN_PW="$(<"${STATE_DIR}/admin_pw")"
[[ -f "${STATE_DIR}/seed.env" ]] && source "${STATE_DIR}/seed.env"
mode="${1:?mode}"
want="${2:-8.0.1}"

# ── Probes ──────────────────────────────────────────────────────────────────
version_is() { [[ "$(ct cat /root/.opencloud)" == "$1" ]]; }
services_up() { ct systemctl is-active opencloud opencloud-wopi coolwsd; }
v8_index_exists() { ct bash -c 'ls -d /var/lib/opencloud/search/bleve-v*'; }
old_index_exists() { ct test -d /var/lib/opencloud/search/bleve; }
admin_login() { api GET /graph/v1.0/me -o /dev/null; }
collabora_registered() { curl -sS --cacert "$CA_FILE" "${OC_URL}/app/list" | grep -q Collabora; }

# search_finds <term> <filename>
search_finds() {
  local body
  body="<?xml version=\"1.0\"?><oc:search-files xmlns:d=\"DAV:\" xmlns:oc=\"http://owncloud.org/ns\"><d:prop><oc:name/></d:prop><oc:search><oc:pattern>name:\"*$1*\"</oc:pattern><oc:limit>50</oc:limit></oc:search></oc:search-files>"
  api REPORT /remote.php/dav/files/admin -H 'Content-Type: application/xml' -d "$body" | tee "${STATE_DIR}/last-search.xml" | grep -q "$2"
}
search_poll() { poll "${3:-600}" search_finds "$1" "$2" || { cat "${STATE_DIR}/last-search.xml"; return 1; }; }

bob_is_member() { api GET "/graph/v1beta1/drives/${SPACE_ID}/root/permissions" | jq -e --arg id "$BOB_ID" '[.value[].grantedToV2.user.id] | index($id) != null'; }
alice_sees_share() { api_as alice "$USER_PW" GET /graph/v1beta1/me/drive/sharedWithMe | jq -e '[.value[].name] | index("nested") != null'; }
public_link_code() {
  curl -sS --cacert "$CA_FILE" -o /dev/null -w '%{http_code}' -X PROPFIND -H 'Depth: 1' "$@"
}
public_link_works() {
  local code path
  # 6.x only routes the legacy /remote.php path; 7.x+ serves both.
  for path in /dav/public-files /remote.php/dav/public-files; do
    code="$(public_link_code -u "public:${LINK_PW}" "${OC_URL}${path}/${LINK_TOKEN}")"
    echo "${path} with password: HTTP ${code}"
    [[ "$code" == 207 ]] || continue
    # The password must actually be enforced.
    code="$(public_link_code "${OC_URL}${path}/${LINK_TOKEN}")"
    echo "${path} without password: HTTP ${code}"
    [[ "$code" == 401 ]] && return 0
  done
  # Diagnostics only
  api GET "/graph/v1beta1/drives/${PERSONAL_ID}/items/${NESTED_ID}/permissions" | jq -c '.value[] | select(.link) | {id, link: .link.type, hasPassword: .hasPassword}'
  return 1
}
log_has() { grep -q -- "$2" "${STATE_DIR}/$1.log"; }
log_lacks() { ! grep -q -- "$2" "${STATE_DIR}/$1.log"; }
env_unchanged() { [[ "$(ct sha256sum /etc/opencloud/opencloud.env)" == "$(<"${STATE_DIR}/env.sha")" ]]; }
admin_pw_unchanged() { [[ "$(admin_password)" == "$ADMIN_PW" ]]; }
service_account_matches() {
  local sharing activity
  sharing="$(ct sed -n '/^sharing:/,/^[a-z]/p' /etc/opencloud/opencloud.yaml | awk '/service_account_id:/ {print $2}')"
  activity="$(ct sed -n '/^activitylog:/,/^[a-z]/p' /etc/opencloud/opencloud.yaml | awk '/service_account_id:/ {print $2}')"
  echo "sharing=${sharing} activitylog=${activity}"
  [[ -n "$sharing" && "$sharing" == "$activity" ]]
}
fresh_upload_indexed() {
  local pid
  pid="$(api GET /graph/v1.0/me/drive | jq -r .id)"
  api PUT "/dav/spaces/${pid}/heron-pickle-3317.txt" --data-binary 'fresh install file' -o /dev/null &&
    search_poll heron heron-pickle-3317.txt 300
}

# ── Phases ──────────────────────────────────────────────────────────────────
case "$mode" in
baseline)
  summary_header "Before update (${want})"
  check "version file is ${want}" version_is "$want"
  check "services running" services_up
  check "search finds personal file" search_poll quokka zebra-quokka-8841.txt 300
  check "search finds space file" search_poll marmot marmot-lantern-5107.txt 300
  check "bob is a QA-Space member" bob_is_member
  check "alice sees shared folder" alice_sees_share
  check "public link opens with password" public_link_works
  ct sha256sum /etc/opencloud/opencloud.env >"${STATE_DIR}/env.sha"
  ;;
fresh)
  summary_header "Fresh install"
  check "version file is ${want}" version_is "$want"
  check "services running" services_up
  check "v8 search index (bleve-v*) created" v8_index_exists
  check "admin login" admin_login
  check "Collabora registered via WOPI discovery" poll 180 collabora_registered
  check "new upload is searchable" fresh_upload_indexed
  ;;
update)
  summary_header "After update"
  check "version file is ${want}" version_is "$want"
  check "services running" services_up
  check "update ran the reindex" log_has update "Rebuilding search index"
  check "update printed old-index warning" log_has update "remove the old index"
  check "v8 search index (bleve-v*) created" v8_index_exists
  check "old index left in place" old_index_exists
  check "search finds personal file" search_poll quokka zebra-quokka-8841.txt 600
  check "search finds nested file" search_poll umbrella umbrella-falcon-2290.md 600
  check "search finds space file" search_poll marmot marmot-lantern-5107.txt 600
  check "bob is still a QA-Space member" bob_is_member
  check "alice still sees shared folder" alice_sees_share
  check "public link still opens with password" public_link_works
  check "opencloud.env unchanged" env_unchanged
  check "admin password unchanged" admin_pw_unchanged
  check "Collabora registered via WOPI discovery" poll 180 collabora_registered
  ;;
migration)
  summary_header "6.x → 8 migration"
  check "sharing.service_account added (matches activitylog)" service_account_matches
  echo "::group::sharing migration log lines"
  ct journalctl -u opencloud --no-pager | grep -i -E 'migrat' | tail -20
  echo "::endgroup::"
  ;;
rerun)
  summary_header "Second update run"
  check "reports no update available" log_has rerun "No update available"
  check "does not reindex again" log_lacks rerun "Rebuilding search index"
  check "services running" services_up
  ;;
*)
  echo "unknown mode: $mode"
  exit 2
  ;;
esac
finish_checks
