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
# HOW. This file stays tiny on purpose. It downloads the hook scripts of one
# reviewed Amora commit (PIN) into ~/.cache/amora-switch/<PIN> and runs the
# one it is asked for.
#   - Cloud only: a hard no-op unless CONDUCTOR_IS_LOCAL=0.
#   - Pinned (2026-09-26, security audit H2). Files are fetched at ?ref=$PIN,
#     never from main, and each must match its SHA-256 in SUMS before the
#     snapshot is installed; one mismatch refuses the whole snapshot. The
#     snapshot is checked against SUMS again before every run, so a copy that
#     doesn't match (say, one an older unpinned copy of this file left) never
#     runs. What Amora merges later does not reach UpOnly until the pin moves.
#   - A snapshot is complete or absent: files land in a temp dir, are checked,
#     then renamed into place.
#   - A pinned snapshot never goes stale, so nothing refreshes in the
#     background. Only the first run in a sandbox downloads, in the foreground.
#     `--refresh`, which older copies of this file started, does nothing.
#   - Old snapshots are kept for a day, because the rescue's background
#     workers keep running from the directory they started in.
#   - Any failure exits 0 with no output: a hook must never block a prompt
#     because GitHub was slow.
#   - This file is itself checked (2026-09-26): each hook command in
#     settings.json runs it only if its SHA-256 matches the one written in that
#     command. Claude Code reads the commands once, when a session starts, so a
#     branch checked out later can't swap in its own copy of this file. Any
#     change here must update that hash in settings.json in the same commit.
#
# BUMPING THE PIN. Read the Amora diff between PIN and the new commit for every
# file in SUMS first (gh api repos/Tonkin-Apps/amora/compare/<PIN>...<new> or
# GitHub's compare page). Then set PIN to the new commit's full SHA and replace
# SUMS with that commit's hashes, from a clean download:
#   for f in <each path in SUMS>; do
#     gh api -H "Accept: application/vnd.github.raw" \
#       "repos/Tonkin-Apps/amora/contents/$f?ref=<new>" | sha256sum | sed "s#-\$#$f#"
#   done
# A hook file Amora adds or drops is added to or removed from SUMS (and the
# case list below) in the same change.
set -uo pipefail

[ "${CONDUCTOR_IS_LOCAL:-}" = "0" ] || exit 0
HOOK="${1:-}"; shift || true
case "$HOOK" in
  conductor_cloud_claude_account.sh|conductor_cloud_claude_guard.sh|\
  conductor_cloud_claude_failover.sh|conductor_cloud_codex_failover.sh|\
  conductor_cloud_claude_bump.sh|conductor_cloud_claude_tick.sh) ;;
  *) exit 0 ;;   # includes --refresh: there is nothing to refresh
esac

export PATH="/conductor/bin:${PATH}"
# Amora's long-lived ticker re-execs through this file when it restarts, so it
# moves to a new pin instead of running its first snapshot forever.
AMORA_ACCOUNT_HOOK_LAUNCHER="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)/$(basename "${BASH_SOURCE[0]}")"
export AMORA_ACCOUNT_HOOK_LAUNCHER
REPO="Tonkin-Apps/amora"
BASE="${HOME}/.cache/amora-switch"
PIN=1f8ba9048cb59df69b0fc9a67203a2bc47f492f3
# sha256sum --check format: "<SHA-256>  <path in Amora>", one line per file.
SUMS="181e528ae95d483c2cfc9efb84de873da6635849e1c88371425cff734e9e5b06  scripts/conductor_cloud_claude_account.sh
0309b46461c2e4f046e3ad7b6911b84713385acb097210465dfa3e647de9fa5f  scripts/conductor_cloud_claude_guard.sh
acb6fae2c695f359d58017ff95f7e7cb33dccb9e56f7a3d910908c8b93e073ed  scripts/conductor_cloud_claude_failover.sh
70c8f239ff8b13ff3eb72ff779a3374335e7261c8258259417cdf348d727937f  scripts/conductor_cloud_codex_failover.sh
6336e5a0491fba7466c44c244f64c8ee6dc1fd25b59d1c4fbda476f10da9e5f2  scripts/conductor_cloud_claude_bump.sh
d7183f3dd5090de14c35d37f438e4b96334f4314262ba3bad66f903dac45b61a  scripts/conductor_cloud_claude_tick.sh
efce247c8140f9fea9ef2cd2dfb77aed4f5d1a95f8d69cebf689e5a5d60fbc8c  scripts/claude_session_rescue.sh
4a66cec45a63b2a8130d0206fdb07950d7eb2ffd8ac21cb15a397c8efcdce8b3  scripts/claude_account_meters.sh
145bde1d0acb3078d5a08f2cd033869d9e1e5459003398a176cdc4b60f681277  scripts/lib/claude_account_common.sh
4c30b9d973ed35832da6e043109c36bccf802325801b5f1021e3a0ce144ecf34  scripts/lib/codex_account_common.sh"
SNAPSHOT="${BASE}/${PIN}"

mkdir -p "$BASE" 2>/dev/null || exit 0

verified() {  # $1 a snapshot dir: true only if every file in SUMS is there with its pinned hash.
  [ -d "$1" ] && (cd "$1" && printf '%s\n' "$SUMS" | sha256sum --check --strict --status) 2>/dev/null
}

fetch() {  # Download PIN's files, check them against SUMS, then install them as SNAPSHOT.
  local tmp _sum f d
  exec 9>"${BASE}/.fetch.lock" || return 1
  flock -w 20 9 || return 1                   # another hook is already fetching
  verified "$SNAPSHOT" && return 0            # ... and it finished
  tmp=$(mktemp -d "${BASE}/.tmp.XXXXXX") || return 1
  while read -r _sum f; do
    if ! mkdir -p "${tmp}/$(dirname "$f")" \
       || ! timeout 15 gh api -H "Accept: application/vnd.github.raw" \
              "repos/${REPO}/contents/${f}?ref=${PIN}" > "${tmp}/${f}" 2>/dev/null; then
      rm -rf "$tmp"; return 1
    fi
  done <<< "$SUMS"
  verified "$tmp" || { rm -rf "$tmp"; return 1; }   # any hash mismatch refuses it all
  chmod +x "${tmp}"/scripts/*.sh
  # A copy of this commit that failed the check is moved aside, then pruned below.
  if [ -e "$SNAPSHOT" ]; then
    mv -T "$SNAPSHOT" "$(mktemp -u "${BASE}/.tmp.XXXXXX")" 2>/dev/null || { rm -rf "$tmp"; return 1; }
  fi
  mv -T "$tmp" "$SNAPSHOT" 2>/dev/null || { rm -rf "$tmp"; return 1; }
  # Prune snapshots older than a day, never the pinned one and never one a
  # running rescue worker was started from.
  find "$BASE" -mindepth 1 -maxdepth 1 -type d -name '.tmp.*' -mmin +60 -exec rm -rf {} + 2>/dev/null
  while IFS= read -r d; do
    pgrep -f "${d}/" >/dev/null 2>&1 || rm -rf "$d"
  done < <(find "$BASE" -mindepth 1 -maxdepth 1 -type d -name '[0-9a-f]*' -mmin +1440 ! -name "$PIN" 2>/dev/null)
  return 0
}

if ! verified "$SNAPSHOT"; then
  ( fetch ) </dev/null >/dev/null 2>&1
  verified "$SNAPSHOT" || exit 0
fi

SNAP="$(cd "${SNAPSHOT}/scripts" 2>/dev/null && pwd -P)" || exit 0
[ -f "${SNAP}/${HOOK}" ] || exit 0
# The guard and failover run a deployed copy of the bump script at a fixed path, ~/.claude/claude-bump.sh, that the
# account hook copies from the snapshot (claude-switch on the Mac runs it there too). A copy that no longer matches the
# pinned file is put back from the snapshot, the same atomic way, so only reviewed code runs; if that fails it's removed.
BUMP="${HOME}/.claude/claude-bump.sh"
if [ -e "$BUMP" ] && ! cmp -s "$BUMP" "${SNAP}/conductor_cloud_claude_bump.sh"; then
  BUMP_TMP="${HOME}/.claude/.claude-bump.sh.$$"
  { cp "${SNAP}/conductor_cloud_claude_bump.sh" "$BUMP_TMP" && chmod 0755 "$BUMP_TMP" && mv -f "$BUMP_TMP" "$BUMP"; } 2>/dev/null \
    || rm -f "$BUMP_TMP" "$BUMP" 2>/dev/null
fi
exec bash "${SNAP}/${HOOK}" "$@"
