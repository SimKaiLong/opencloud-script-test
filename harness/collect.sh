#!/usr/bin/env bash
# Print container state and gather logs into ./artifacts. Never fails.
# Run as root.
out="${1:-artifacts}"
mkdir -p "$out"

incus list | tee "$out/incus-list.txt"
cp /tmp/incus-install-*.log /tmp/ct-opencloud.sh "$out/" 2>/dev/null
cp -r /usr/local/community-scripts "$out/community-scripts-state" 2>/dev/null

for ct in $(incus list -c n -f csv); do
  echo "::group::${ct}"
  incus exec "$ct" -- bash -c '
    echo "version file: $(cat ~/.opencloud 2>/dev/null)"
    for s in opencloud opencloud-wopi coolwsd; do echo "$s: $(systemctl is-active $s)"; done
    ls -la /var/lib/opencloud/search 2>&1
  ' 2>&1 | tee "$out/${ct}-state.txt"
  incus exec "$ct" -- journalctl -u opencloud -u opencloud-wopi -u coolwsd --no-pager -n 300 >"$out/${ct}-journal.txt" 2>&1
  incus exec "$ct" -- bash -c 'cat /root/.install-*.log' >"$out/${ct}-install.log" 2>&1
  echo "::endgroup::"
done
cp /tmp/oc-test/*.log /tmp/oc-test/last-search.xml "$out/" 2>/dev/null
# Artifacts are public: drop generated passwords.
sed -i -E 's/(password +: ).*/\1[redacted]/' "$out"/*.log "$out"/*.txt 2>/dev/null
exit 0
