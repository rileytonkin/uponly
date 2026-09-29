#!/usr/bin/env bash
# Up Only on TestFlight, from the owner's Mac, with the App Store Connect CLI (`asc`, 5.7.0 or later).
# docs/IOS_TESTFLIGHT.md explains each step. Nothing here runs in CI: the repository is public and holds no secrets.
#
#   scripts/ios_testflight.sh doctor           check asc, the API key, Xcode and the local settings; changes nothing
#   scripts/ios_testflight.sh setup            one time: bundle ID, app record, Internal group (asks before each)
#   scripts/ios_testflight.sh upload [NOTES]   archive, export, check the signature, upload, add to Internal
#
# Local settings live outside the repository, in ~/.config/uponly/release.env (never commit it):
#   UPONLY_TEAM_ID=...            Tonkin Apps' team ID, for signing
#   UPONLY_ASC_APP_ID=...         the app's App Store Connect ID, printed by `setup`
#   UPONLY_TESTER_EMAIL=...       optional: added to the Internal group by `setup`
#   ASC_KEY_ID / ASC_ISSUER_ID / ASC_PRIVATE_KEY_PATH   the Tonkin Apps API key (Admin role, for cloud signing).
#     When unset, Amora's ~/.config/amora/asc.env (the same team's key) is used.
set -euo pipefail

BUNDLE_ID=com.tonkinapps.up
APP_NAME="Up Only"
SKU=UPONLY-IOS
GROUP=Internal
SCHEME=UpOnlyiOS
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CONFIG=${UPONLY_RELEASE_ENV:-$HOME/.config/uponly/release.env}

die() { printf 'ios_testflight: %s\n' "$1" >&2; exit 1; }
confirm() { read -r -p "$1 [y/N] " answer; [ "$answer" = y ] || [ "$answer" = Y ]; }
json() { python3 -c "import json, sys; d = json.load(sys.stdin); print($1)"; }

load_config() {
  # shellcheck disable=SC1090
  [ -f "$CONFIG" ] && . "$CONFIG"
  if [ -z "${ASC_KEY_ID:-}" ] && [ -f "$HOME/.config/amora/asc.env" ]; then
    # shellcheck disable=SC1091
    . "$HOME/.config/amora/asc.env"
    ASC_KEY_ID=${AMORA_ASC_KEY_ID:-}; ASC_ISSUER_ID=${AMORA_ASC_ISSUER_ID:-}
    ASC_PRIVATE_KEY_PATH=$(eval echo "${AMORA_ASC_PRIVATE_KEY_PATH:-}")
  fi
  export ASC_KEY_ID="${ASC_KEY_ID:-}" ASC_ISSUER_ID="${ASC_ISSUER_ID:-}" ASC_PRIVATE_KEY_PATH="${ASC_PRIVATE_KEY_PATH:-}"
}

# xcodebuild signs with the API key, so no Apple ID needs to be signed in to Xcode.
signing_flags() {
  local tool=$1
  printf -- '--%s=-allowProvisioningUpdates\n' "$tool"
  if [ -n "$ASC_PRIVATE_KEY_PATH" ]; then
    printf -- '--%s=-authenticationKeyPath\n--%s=%s\n' "$tool" "$tool" "$ASC_PRIVATE_KEY_PATH"
    printf -- '--%s=-authenticationKeyID\n--%s=%s\n' "$tool" "$tool" "$ASC_KEY_ID"
    printf -- '--%s=-authenticationKeyIssuerID\n--%s=%s\n' "$tool" "$tool" "$ASC_ISSUER_ID"
  fi
}

doctor() {
  load_config
  command -v asc >/dev/null || die "asc isn't installed (brew install asc)"
  local version; version=$(asc --version | awk '{ print $1 }')
  python3 -c "import sys; v = tuple(map(int, '$version'.split('.')[:2])); sys.exit(v < (5, 7))" \
    || die "asc $version is older than 5.7.0 (brew upgrade asc)"
  echo "asc $version"
  [ -n "$ASC_KEY_ID" ] && [ -n "$ASC_ISSUER_ID" ] && [ -f "$ASC_PRIVATE_KEY_PATH" ] \
    || die "no App Store Connect API key: set ASC_KEY_ID, ASC_ISSUER_ID and ASC_PRIVATE_KEY_PATH in $CONFIG"
  ASC_READ_ONLY=1 asc apps list --bundle-id "$BUNDLE_ID" --output json >/dev/null || die "the API key doesn't work (asc auth doctor)"
  echo "API key $ASC_KEY_ID works"
  asc xcode doctor --sdk iphoneos --output table
  [ -n "${UPONLY_TEAM_ID:-}" ] || die "set UPONLY_TEAM_ID in $CONFIG"
  if [ -n "${UPONLY_ASC_APP_ID:-}" ]; then echo "app $UPONLY_ASC_APP_ID"; else echo "no UPONLY_ASC_APP_ID yet: run setup"; fi
}

setup() {
  doctor
  # Every read here is read-only; each change asks first.
  if [ "$(ASC_READ_ONLY=1 asc bundle-ids list --identifier "$BUNDLE_ID" --output json | json 'len(d.get("data", []))')" = 0 ]; then
    confirm "Register the bundle ID $BUNDLE_ID?" || die "stopped"
    asc bundle-ids create --identifier "$BUNDLE_ID" --name "$APP_NAME" --platform IOS --output table
  else echo "bundle ID $BUNDLE_ID is registered"; fi

  local app; app=$(ASC_READ_ONLY=1 asc apps list --bundle-id "$BUNDLE_ID" --output json | json 'd["data"][0]["id"] if d.get("data") else ""')
  if [ -z "$app" ]; then
    # Apple's public API can't create apps, so this one step signs in to App Store Connect on the web (with 2FA once).
    # It stops rather than quietly renaming the app if the name is taken.
    confirm "Create the App Store Connect app \"$APP_NAME\" ($BUNDLE_ID, SKU $SKU)?" || die "stopped"
    asc web apps create --name "$APP_NAME" --bundle-id "$BUNDLE_ID" --sku "$SKU" --platform IOS \
      --primary-locale en-US --auto-rename=false --output table
    app=$(ASC_READ_ONLY=1 asc apps list --bundle-id "$BUNDLE_ID" --output json | json 'd["data"][0]["id"]')
  fi
  echo "app $app: add UPONLY_ASC_APP_ID=$app to $CONFIG"

  if [ "$(ASC_READ_ONLY=1 asc testflight groups list --app "$app" --internal --name "$GROUP" --output json | json 'len(d.get("data", []))')" = 0 ]; then
    confirm "Create the internal TestFlight group \"$GROUP\"?" || die "stopped"
    asc testflight groups create --app "$app" --name "$GROUP" --internal --access-all-builds --output table
  else echo "group $GROUP exists"; fi
  if [ -n "${UPONLY_TESTER_EMAIL:-}" ] && confirm "Add $UPONLY_TESTER_EMAIL to $GROUP?"; then
    asc testflight testers add --app "$app" --email "$UPONLY_TESTER_EMAIL" --group "$GROUP" --output table
  fi
}

upload() {
  doctor
  [ -n "${UPONLY_ASC_APP_ID:-}" ] || die "set UPONLY_ASC_APP_ID in $CONFIG (setup prints it)"
  local notes=${1:-$ROOT/ios/metadata/en-US/whats_new.txt}
  [ -f "$notes" ] || die "no What to Test notes at $notes"
  [ -z "$(git -C "$ROOT" status --porcelain)" ] || die "the working tree has changes: upload builds only what's committed"

  # A build number from the time, always larger than the last, with no project file to edit.
  local version build dir
  version=$(sed -n 's/.*MARKETING_VERSION = \(.*\);/\1/p' "$ROOT/UpOnly.xcodeproj/project.pbxproj" | sort -u | tail -1)
  build=$(date -u +%Y%m%d%H%M)
  dir="$ROOT/.context/releases/ios/$version/$build"
  mkdir -p "$dir"
  echo "Up Only $version ($build) from $(git -C "$ROOT" rev-parse --short HEAD), artifacts in $dir"

  local flags=()
  while IFS= read -r flag; do flags+=("$flag"); done < <(signing_flags xcodebuild-flag)
  asc xcode archive --project "$ROOT/UpOnly.xcodeproj" --scheme "$SCHEME" --configuration Release \
    --archive-path "$dir/UpOnly.xcarchive" --overwrite \
    --xcodebuild-flag=-destination --xcodebuild-flag=generic/platform=iOS \
    --xcodebuild-flag="DEVELOPMENT_TEAM=$UPONLY_TEAM_ID" --xcodebuild-flag="CURRENT_PROJECT_VERSION=$build" \
    "${flags[@]}" --output table
  asc xcode export --archive-path "$dir/UpOnly.xcarchive" --ipa-path "$dir/UpOnly.ipa" --overwrite \
    --method app-store-connect --signing-style automatic --team-id "$UPONLY_TEAM_ID" "${flags[@]}" --output table

  # Before anything leaves the Mac: the right app, signed for the App Store by Tonkin Apps, not debuggable.
  asc ipa-info --path "$dir/UpOnly.ipa" --include-profile --include-entitlements --output json > "$dir/ipa-info.json"
  python3 - "$dir/ipa-info.json" "$BUNDLE_ID" "$UPONLY_TEAM_ID" "$build" <<'PY'
import json, sys
info, bundle, team, build = json.load(open(sys.argv[1])), *sys.argv[2:]
problems = []
if info.get("bundleId") != bundle: problems.append(f"bundle ID {info.get('bundleId')}, expected {bundle}")
if info.get("buildNumber") != build: problems.append(f"build {info.get('buildNumber')}, expected {build}")
if (info.get("signer") or {}).get("teamId") != team: problems.append(f"signed by team {(info.get('signer') or {}).get('teamId')}, expected {team}")
if (info.get("profile") or {}).get("profileType") != "app-store": problems.append(f"profile type {(info.get('profile') or {}).get('profileType')}, expected app-store")
if (info.get("entitlements") or {}).get("get-task-allow"): problems.append("get-task-allow is set")
if problems: sys.exit("ios_testflight: the IPA failed its checks: " + "; ".join(problems))
print("IPA checks passed: " + bundle + ", team " + team + ", app-store profile, no get-task-allow")
PY

  asc publish testflight --app "$UPONLY_ASC_APP_ID" --ipa "$dir/UpOnly.ipa" --group "$GROUP" \
    --test-notes "@file:$notes" --locale en-US --wait --output json | tee "$dir/publish.json"
  echo "Up Only $version ($build) is on TestFlight in $GROUP."
}

case "${1:-}" in
  doctor) doctor ;;
  setup) setup ;;
  upload) shift; upload "$@" ;;
  *) sed -n '2,15p' "$0"; exit 2 ;;
esac
