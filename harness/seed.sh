#!/usr/bin/env bash
# Create data an upgrade must preserve, and record what was created in
# $STATE_DIR/seed.env for verify.sh. Run as root after tls-setup.sh.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
ADMIN_PW="$(<"${STATE_DIR}/admin_pw")"

USER_PW='Qa-User-8841!x'
LINK_PW='Qa-Link-8841!x'
# Unified role IDs (libre graph): space editor, and viewer for item shares.
ROLE_SPACE_EDITOR=58c63c02-1d89-4572-916a-870abc5a1b7d
ROLE_VIEWER=b1e2218d-eef8-4d4c-b82d-0f1a1b48f3b5

create_user() {
  api POST /graph/v1.0/users -H 'Content-Type: application/json' -d "{
    \"onPremisesSamAccountName\": \"$1\", \"displayName\": \"$1\",
    \"mail\": \"$1@oc.test\", \"passwordProfile\": {\"password\": \"${USER_PW}\"}}" | jq -r .id
}

# fileid of a path inside a space
file_id() {
  api PROPFIND "/dav/spaces/$1/$2" -H 'Depth: 0' -H 'Content-Type: application/xml' \
    -d '<?xml version="1.0"?><d:propfind xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns"><d:prop><oc:fileid/></d:prop></d:propfind>' |
    sed -n 's:.*<oc\:fileid>\([^<]*\)</oc\:fileid>.*:\1:p' | head -1
}

echo "::group::Users"
ALICE_ID="$(create_user alice)"
BOB_ID="$(create_user bob)"
# First login provisions each user's personal space.
api_as alice "$USER_PW" GET /graph/v1.0/me/drives -o /dev/null
api_as bob "$USER_PW" GET /graph/v1.0/me/drives -o /dev/null
echo "alice=${ALICE_ID} bob=${BOB_ID}"
echo "::endgroup::"

echo "::group::Spaces and files"
PERSONAL_ID="$(api GET /graph/v1.0/me/drive | jq -r .id)"
SPACE_ID="$(api POST /graph/v1.0/drives -H 'Content-Type: application/json' \
  -d '{"name":"QA-Space","driveType":"project","quota":{"total":1000000000}}' | jq -r .id)"
echo "personal=${PERSONAL_ID} space=${SPACE_ID}"

api PUT "/dav/spaces/${PERSONAL_ID}/zebra-quokka-8841.txt" --data-binary 'personal file before upgrade' -o /dev/null
api MKCOL "/dav/spaces/${PERSONAL_ID}/nested" -o /dev/null
api PUT "/dav/spaces/${PERSONAL_ID}/nested/umbrella-falcon-2290.md" --data-binary '# nested file before upgrade' -o /dev/null
api PUT "/dav/spaces/${SPACE_ID}/marmot-lantern-5107.txt" --data-binary 'space file before upgrade' -o /dev/null
echo "::endgroup::"

echo "::group::Membership, share, public link"
api POST "/graph/v1beta1/drives/${SPACE_ID}/root/invite" -H 'Content-Type: application/json' -d "{
  \"recipients\": [{\"objectId\": \"${BOB_ID}\", \"@libre.graph.recipient.type\": \"user\"}],
  \"roles\": [\"${ROLE_SPACE_EDITOR}\"]}" -o /dev/null

NESTED_ID="$(file_id "$PERSONAL_ID" nested)"
api POST "/graph/v1beta1/drives/${PERSONAL_ID}/items/${NESTED_ID}/invite" -H 'Content-Type: application/json' -d "{
  \"recipients\": [{\"objectId\": \"${ALICE_ID}\", \"@libre.graph.recipient.type\": \"user\"}],
  \"roles\": [\"${ROLE_VIEWER}\"]}" -o /dev/null

LINK_URL="$(api POST "/graph/v1beta1/drives/${PERSONAL_ID}/items/${NESTED_ID}/createLink" \
  -H 'Content-Type: application/json' -d "{\"type\": \"view\", \"password\": \"${LINK_PW}\"}" | jq -r .link.webUrl)"
LINK_TOKEN="${LINK_URL##*/}"
echo "link token=${LINK_TOKEN}"
echo "::endgroup::"

# Drive IDs contain '$', so quote every value.
for v in USER_PW LINK_PW ALICE_ID BOB_ID PERSONAL_ID SPACE_ID NESTED_ID LINK_TOKEN; do
  printf '%s=%q\n' "$v" "${!v}"
done >"${STATE_DIR}/seed.env"
echo "Seeded."
