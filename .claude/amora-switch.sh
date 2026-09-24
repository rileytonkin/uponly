#!/usr/bin/env bash
# Run Amora's Claude/Codex account-switching hooks in this repository's cloud
# workspaces.
#
# WHY (2026-09-24). Switch's rescue (move a chat to an account with room when
# its account hits a limit, in the same tab) lives in Tonkin-Apps/amora and
# only ran in Amora workspaces. An UpOnly chat ran on Conductor's built-in
# login, hit its limit, and sat dead while acc3 had room. Nothing reached it:
# no hooks here, and the Mac's switcher had no SSH route to the sandbox.
#
# HOW. This file stays tiny on purpose. It downloads the hook scripts from
# Amora's main branch into ~/.cache/amora-switch and runs the one it is asked
# for, so every fix merged in Amora reaches UpOnly with no change here.
#   - Cloud only: a hard no-op unless CONDUCTOR_IS_LOCAL=0.
#   - A snapshot is complete or absent: files land in a temp dir, are
#     syntax-checked, then renamed into place and pointed at by `current`.
#   - Stale snapshots (older than 10 minutes) are refreshed in the background;
#     the hook runs on the existing one, so a prompt never waits on GitHub.
#     Only the very first run of a sandbox downloads in the foreground.
#   - A downloaded file must start with "#" and pass bash -n, so a GitHub
#     error page saved as a script is refused (gh can exit 0 on failure).
#   - Old snapshots are kept for a day, because the rescue's background
#     workers keep running from the directory they started in.
#   - Any failure exits 0 with no output: a hook must never block a prompt
#     because GitHub was slow.
set -uo pipefail

[ "${CONDUCTOR_IS_LOCAL:-}" = "0" ] || exit 0
HOOK="${1:-}"; shift || true
REFRESH_ONLY=0
[ "$HOOK" = "--refresh" ] && { REFRESH_ONLY=1; HOOK=conductor_cloud_claude_guard.sh; }
case "$HOOK" in
  conductor_cloud_claude_account.sh|conductor_cloud_claude_guard.sh|\
  conductor_cloud_claude_failover.sh|conductor_cloud_codex_failover.sh|\
  conductor_cloud_claude_bump.sh|conductor_cloud_claude_tick.sh) ;;
  *) exit 0 ;;
esac

export PATH="/conductor/bin:${PATH}"
# Amora's long-lived ticker re-execs through this file when it restarts, so it
# moves to the newest snapshot instead of running its first one forever.
AMORA_ACCOUNT_HOOK_LAUNCHER="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)/$(basename "${BASH_SOURCE[0]}")"
export AMORA_ACCOUNT_HOOK_LAUNCHER
REPO="Tonkin-Apps/amora"
BASE="${HOME}/.cache/amora-switch"
FILES="scripts/conductor_cloud_claude_account.sh
scripts/conductor_cloud_claude_guard.sh
scripts/conductor_cloud_claude_failover.sh
scripts/conductor_cloud_codex_failover.sh
scripts/conductor_cloud_claude_bump.sh
scripts/conductor_cloud_claude_tick.sh
scripts/claude_session_rescue.sh
scripts/claude_account_meters.sh
scripts/lib/claude_account_common.sh
scripts/lib/codex_account_common.sh"
STALE_AFTER=600

mkdir -p "$BASE" 2>/dev/null || exit 0

fetch() {  # $1 seconds to wait for another fetch. Download main's copy, make it current.
  local sha tmp f
  exec 9>"${BASE}/.fetch.lock" || return 1
  flock -w "${1:-0}" 9 || return 1            # another hook is already fetching
  [ "${1:-0}" -gt 0 ] && [ -f "${BASE}/current/scripts/${HOOK}" ] && return 0
  sha=$(timeout 10 gh api "repos/${REPO}/commits/main" --jq .sha 2>/dev/null) || return 1
  case "$sha" in *[!0-9a-f]*|'') return 1 ;; esac
  [ ${#sha} -eq 40 ] || return 1
  if [ -d "${BASE}/${sha}" ]; then
    ln -sfn "$sha" "${BASE}/current.new" && mv -Tf "${BASE}/current.new" "${BASE}/current"
    touch "${BASE}/${sha}"
    return 0
  fi
  tmp=$(mktemp -d "${BASE}/.tmp.XXXXXX") || return 1
  while IFS= read -r f; do
    mkdir -p "${tmp}/$(dirname "$f")"
    timeout 15 gh api -H "Accept: application/vnd.github.raw" \
      "repos/${REPO}/contents/${f}?ref=${sha}" > "${tmp}/${f}" 2>/dev/null \
      && [ "$(head -c 1 "${tmp}/${f}")" = '#' ] && bash -n "${tmp}/${f}" 2>/dev/null \
      || { rm -rf "$tmp"; return 1; }
  done <<< "$FILES"
  chmod +x "${tmp}"/scripts/*.sh
  mv -T "$tmp" "${BASE}/${sha}" 2>/dev/null || { rm -rf "$tmp"; return 1; }
  ln -sfn "$sha" "${BASE}/current.new" && mv -Tf "${BASE}/current.new" "${BASE}/current"
  # Prune snapshots older than a day, never the current one and never one a
  # running rescue worker was started from.
  local d
  find "$BASE" -mindepth 1 -maxdepth 1 -type d -name '.tmp.*' -mmin +60 -exec rm -rf {} + 2>/dev/null
  for d in $(find "$BASE" -mindepth 1 -maxdepth 1 -type d -name '[0-9a-f]*' -mmin +1440 ! -name "$sha" 2>/dev/null); do
    pgrep -f "${d}/" >/dev/null 2>&1 || rm -rf "$d"
  done
  return 0
}

if [ "$REFRESH_ONLY" = 1 ]; then
  fetch 0
  exit 0
fi

if [ -f "${BASE}/current/scripts/${HOOK}" ]; then
  age=$(( $(date +%s) - $(stat -c %Y "${BASE}/current" 2>/dev/null || echo 0) ))
  if [ "$age" -gt "$STALE_AFTER" ]; then
    touch -h "${BASE}/current" 2>/dev/null      # one refresher per interval
    setsid bash "$AMORA_ACCOUNT_HOOK_LAUNCHER" --refresh </dev/null >/dev/null 2>&1 &
  fi
else
  ( fetch 20 ) </dev/null >/dev/null 2>&1 || true
fi

SNAP="${BASE}/current/scripts"
[ -f "${SNAP}/${HOOK}" ] || exit 0
SNAP="$(cd "$SNAP" 2>/dev/null && pwd -P)" || exit 0
exec bash "${SNAP}/${HOOK}" "$@"
