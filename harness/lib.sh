#!/usr/bin/env bash
# Shared helpers. Source from the other harness scripts; run as root.

STATE_DIR="${STATE_DIR:-/tmp/oc-test}"
CA_FILE="${STATE_DIR}/caddy-root.crt"
OC_URL="https://cloud.oc.test"
mkdir -p "$STATE_DIR"

# The single container the ct script created.
ct_name() {
  incus list -c n -f csv | head -1
}

ct() {
  incus exec "$(ct_name)" -- "$@"
}

# yaml_unquote: drop YAML single/double quotes ('' is an escaped ' inside single quotes)
yaml_unquote() {
  local v="$1"
  if [[ "$v" == \'*\' ]]; then
    v="${v:1:${#v}-2}"
    v="${v//\'\'/\'}"
  elif [[ "$v" == \"*\" ]]; then
    v="${v:1:${#v}-2}"
  fi
  printf '%s' "$v"
}

admin_password() {
  local raw
  raw="$(ct sed -n '/^idm:/,/^[a-z]/p' /etc/opencloud/opencloud.yaml | sed -n 's/^ *admin_password: //p' | head -1)"
  yaml_unquote "$raw"
}

# api <method> <path> [curl args...] — authenticated call as admin, body on stdout.
api() {
  local method="$1" path="$2"
  shift 2
  curl -sS --fail-with-body --cacert "$CA_FILE" -u "admin:${ADMIN_PW:?}" -X "$method" "${OC_URL}${path}" "$@"
}

# api_as <user> <password> <method> <path> [curl args...]
api_as() {
  local user="$1" pw="$2" method="$3" path="$4"
  shift 4
  curl -sS --fail-with-body --cacert "$CA_FILE" -u "${user}:${pw}" -X "$method" "${OC_URL}${path}" "$@"
}

# poll <seconds> <command...> — retry every 10s until the command succeeds.
poll() {
  local deadline=$((SECONDS + $1))
  shift
  until "$@"; do
    ((SECONDS >= deadline)) && return 1
    sleep 10
  done
}

# ── Check reporting ─────────────────────────────────────────────────────────
CHECK_FAILS=0
check() {
  local name="$1"
  shift
  local out rc=0
  out="$("$@" 2>&1)" || rc=$?
  if ((rc == 0)); then
    echo "PASS  ${name}"
    echo "| ✅ | ${name} |" >>"${GITHUB_STEP_SUMMARY:-/dev/null}"
  else
    echo "::error::FAIL  ${name}"
    printf '%s\n' "$out" | tail -20 | sed 's/^/      /'
    echo "| ❌ | ${name} |" >>"${GITHUB_STEP_SUMMARY:-/dev/null}"
    CHECK_FAILS=$((CHECK_FAILS + 1))
  fi
}

summary_header() {
  {
    echo "### $1"
    echo "| | Check |"
    echo "|---|---|"
  } >>"${GITHUB_STEP_SUMMARY:-/dev/null}"
}

finish_checks() {
  echo >>"${GITHUB_STEP_SUMMARY:-/dev/null}"
  ((CHECK_FAILS == 0)) || { echo "${CHECK_FAILS} check(s) failed"; exit 1; }
}
