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
reindex_finished() {
  ct journalctl -u opencloud-reindex --no-pager -o cat >"${STATE_DIR}/reindex.log" 2>&1
  tail -3 "${STATE_DIR}/reindex.log"
  # last progress line reads "[N/N] indexed space ..."
  awk -F'[][/]' '/indexed space/ {done = ($2 == $3)} END {exit !done}' "${STATE_DIR}/reindex.log" &&
    grep -q 'opencloud-reindex.service: Deactivated successfully' "${STATE_DIR}/reindex.log"
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
# ── Integrity (against seed.sh's manifest) ──────────────────────────────────
users_unchanged() {
  diff <(api GET /graph/v1.0/users | jq -r '[.value[] | "\(.id) \(.onPremisesSamAccountName)"] | sort | .[]') "${STATE_DIR}/users.txt"
}
user_can_login() { api_as "$1" "$USER_PW" GET /graph/v1.0/me | jq -e --arg u "$1" '.onPremisesSamAccountName == $u'; }

contents_intact() {
  local drive path sum fid now bad=0 n=0
  while IFS='|' read -r drive path sum fid; do
    n=$((n + 1))
    now="$(api GET "/dav/spaces/${drive}/${path}" | sha256sum | cut -d' ' -f1)"
    [[ "$now" == "$sum" ]] || { bad=$((bad + 1)); echo "checksum mismatch: ${path}"; }
  done <"${STATE_DIR}/manifest.txt"
  echo "${n} files compared, ${bad} mismatched"
  ((n > 300 && bad == 0))
}
fileids_unchanged() {
  local drive path sum fid now bad=0 n=0
  while IFS='|' read -r drive path sum fid; do
    n=$((n + 1))
    now="$(api PROPFIND "/dav/spaces/${drive}/${path}" -H 'Depth: 0' -H 'Content-Type: application/xml' \
      -d '<?xml version="1.0"?><d:propfind xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns"><d:prop><oc:fileid/></d:prop></d:propfind>' |
      sed -n 's:.*<oc\:fileid>\([^<]*\)</oc\:fileid>.*:\1:p' | head -1)"
    [[ -n "$fid" && "$now" == "$fid" ]] || { bad=$((bad + 1)); echo "fileid changed: ${path} ${fid} -> ${now}"; }
  done <"${STATE_DIR}/manifest.txt"
  echo "${n} file IDs compared, ${bad} changed"
  ((n > 300 && bad == 0))
}
versions_kept() {
  local fid count
  fid="$(awk -F'|' '$2 == "zebra-quokka-8841.txt" {print $4}' "${STATE_DIR}/manifest.txt")"
  count="$(api PROPFIND "/remote.php/dav/meta/${fid}/v" -H 'Depth: 1' | grep -o '<d:response>' | wc -l)"
  # The listing includes the collection itself.
  echo "noncurrent versions: $((count - 1))"
  ((count - 1 >= 2))
}
trash_kept() {
  api PROPFIND "/remote.php/dav/spaces/trash-bin/${PERSONAL_ID}" -H 'Depth: 1' | grep -q 'deleted-otter-6620.txt'
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
  check "alice can log in" user_can_login alice
  check "bob can log in" user_can_login bob
  check "file has 2 older versions" versions_kept
  check "deleted file is in trash" trash_kept
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
  check "update started the reindex unit" log_has update "Started search index rebuild"
  check "reindex unit indexed every space and exited cleanly" poll 900 reindex_finished
  check "update printed old-index warning" log_has update "remove the old index"
  check "v8 search index (bleve-v*) created" v8_index_exists
  check "old index left in place" old_index_exists
  check "search finds personal file" search_poll quokka zebra-quokka-8841.txt 600
  check "search finds nested file" search_poll umbrella umbrella-falcon-2290.md 600
  check "search finds space file" search_poll marmot marmot-lantern-5107.txt 600
  check "bob is still a QA-Space member" bob_is_member
  check "alice still sees shared folder" alice_sees_share
  check "public link still opens with password" public_link_works
  check "user list unchanged" users_unchanged
  check "alice can still log in" user_can_login alice
  check "bob can still log in" user_can_login bob
  check "all 303 file contents intact (sha256)" contents_intact
  check "all file IDs unchanged (no client resync)" fileids_unchanged
  check "older file versions kept" versions_kept
  check "trash kept" trash_kept
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
  check "does not reindex again" log_lacks rerun "search index rebuild"
  check "services running" services_up
  ;;
*)
  echo "unknown mode: $mode"
  exit 2
  ;;
esac
finish_checks
