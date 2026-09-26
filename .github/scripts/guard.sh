#!/usr/bin/env bash
# Repository guard, run by CI on every pull request and push to main.
# Fails when a change would:
#   - run code at build time (Run Script phases, build rules, external build
#     tools, scheme pre/post actions) or pull in Swift packages;
#   - let a development-signed Release build of the app carry get-task-allow;
#   - add an entitlement beyond the sandbox, network client, user-selected
#     files and keychain group;
#   - commit something that looks like a secret, a vault, a backup or a
#     plaintext file from the app's container.
# Run it from the repository root: bash .github/scripts/guard.sh
set -uo pipefail

PBX=UpOnly.xcodeproj/project.pbxproj
failures=0
fail() { printf '::error::%s\n' "$1"; failures=$((failures + 1)); }

[ -f "$PBX" ] || { fail "$PBX not found; run from the repository root"; exit 1; }

# 1. Nothing that runs code at build time, and no Swift packages.
for pattern in shellScript PBXShellScriptBuildPhase PBXBuildRule PBXLegacyTarget \
               XCRemoteSwiftPackageReference XCLocalSwiftPackageReference; do
  grep -q "$pattern" "$PBX" && fail "$PBX contains $pattern"
done
while IFS= read -r scheme; do
  grep -qE 'PreActions|PostActions|ShellScriptAction' "$scheme" && fail "$scheme has a pre- or post-action script"
done < <(git ls-files '*.xcscheme')

# 2. The app target's Release configuration must not inject get-task-allow.
list=$(awk '/Build configuration list for PBXNativeTarget "UpOnly" \*\/ = \{/ { f = 1; next }
            f && /\/\* Release \*\// { print $1; exit }
            f && /^\t\t\};/ { exit }' "$PBX")
if [ -z "$list" ]; then
  fail "could not find the UpOnly target's Release configuration in $PBX"
else
  block=$(awk -v id="$list" '$1 == id && /= \{/ { f = 1 } f { print } f && /^\t\t\};/ { exit }' "$PBX")
  grep -q 'CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO;' <<< "$block" \
    || fail "the UpOnly target's Release configuration must set CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO"
fi

# 3. Entitlements: only the expected keys, never get-task-allow, and every
#    CODE_SIGN_ENTITLEMENTS points at one of the files checked here.
allowed="com.apple.security.app-sandbox
com.apple.security.network.client
com.apple.security.files.user-selected.read-write
keychain-access-groups"
entitlements=$(git ls-files '*.entitlements')
[ -n "$entitlements" ] || fail "no .entitlements files found"
while IFS= read -r file; do
  [ -n "$file" ] || continue
  grep -q 'get-task-allow' "$file" && fail "$file contains get-task-allow"
  while IFS= read -r key; do
    grep -qxF -- "$key" <<< "$allowed" || fail "$file has an entitlement outside the allowed set: $key"
  done < <(tr -d '\n\r' < "$file" | grep -oE '<key>[^<]*</key>' | sed -E 's#</?key>##g; s/^[[:space:]]+|[[:space:]]+$//g')
done <<< "$entitlements"
while IFS= read -r path; do
  grep -qxF -- "$path" <<< "$entitlements" || fail "CODE_SIGN_ENTITLEMENTS points at $path, which is not a tracked .entitlements file"
done < <(sed -nE 's/.*CODE_SIGN_ENTITLEMENTS = "?([^";]*)"?;.*/\1/p' "$PBX" | sort -u)

# 4. No secrets in tracked files.
secrets='-----BEGIN [A-Z ]*PRIVATE KEY-----|ghp_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{20,}|AIza[0-9A-Za-z_-]{35}|(^|[^A-Za-z0-9_-])sk-[A-Za-z0-9_-]{20,}|"private_key"[[:space:]]*:'
if hits=$(git grep -nIE -e "$secrets" -- . 2>/dev/null); then
  while IFS= read -r hit; do fail "possible secret: ${hit%%:*}:$(cut -d: -f2 <<< "$hit")"; done <<< "$hits"
fi

# 5. No vaults, backups or plaintext container files, even encrypted ones.
if files=$(git ls-files | grep -E '(^|/)[^/]*\.(uponly|wrapper)[^/]*(/|$)|\.sealed$|(^|/)(diagnostics\.txt|unlock-timing\.json|accounting-audit\.json)$'); then
  while IFS= read -r file; do fail "vault, backup or container file is tracked: $file"; done <<< "$files"
fi

if [ "$failures" -gt 0 ]; then
  echo "guard: $failures problem(s)"
  exit 1
fi
echo "guard: ok"
