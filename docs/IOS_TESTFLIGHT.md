# Up Only on iPhone: TestFlight

The iPhone app is the `UpOnlyiOS` target (`com.tonkinapps.up`, Tonkin Apps). It compiles the Mac app's engine and pages; the iPhone-only pieces are in [`ios/`](../ios). CI builds it for the simulator on every pull request. Uploading happens only from the owner's Mac, with the [App Store Connect CLI](https://github.com/rorkai/App-Store-Connect-CLI) (`asc` 5.7.0 or later) and [`scripts/ios_testflight.sh`](../scripts/ios_testflight.sh). The repository is public, so no step of this runs in CI and no key or team ID is committed.

## What's automated, and what isn't

| Step | How |
|---|---|
| Check asc, the API key and Xcode | `scripts/ios_testflight.sh doctor` (read-only) |
| Register the bundle ID | `setup`: `asc bundle-ids create` |
| Create the App Store Connect app | `setup`: `asc web apps create`. Apple's public API can't create apps, so this is the one step that signs in to App Store Connect on the web, with two-factor authentication the first time. It stops if the name "Up" is taken rather than renaming the app. |
| Internal TestFlight group, and adding you to it | `setup`: `asc testflight groups create --internal`, `asc testflight testers add` |
| Export compliance | Never asked: `ios/Info.plist` sets `ITSAppUsesNonExemptEncryption` to false (the app uses only Apple's encryption, for your own data) |
| Signing | Automatic, cloud-managed, with the API key: `-allowProvisioningUpdates` and the key's `-authenticationKey…` flags. No Apple ID needs to be signed in to Xcode. |
| Build number | The UTC time (`202609281530`), always larger than the last; the project file isn't edited |
| Archive, export, check, upload, wait, add to Internal, What to Test | `upload`: `asc xcode archive`, `asc xcode export`, `asc ipa-info`, `asc publish testflight --wait` |

`setup` asks before each change. `upload` refuses a working tree with uncommitted changes, and checks the exported IPA before it leaves the Mac: the bundle ID, the build number, a Tonkin Apps signature, an App Store profile, and no `get-task-allow`. Artifacts and logs go to `.context/releases/ios/<version>/<build>/` (ignored by git).

Still manual: the owner's go-ahead for each run on the Mac (AGENTS.md), installing TestFlight on the phone, and testing.

External testers need more (a privacy policy at `up.tonkinapps.com/privacy`, a beta description and feedback email, and Apple's beta review, about a day). `asc testflight review` and `asc publish testflight --submit --confirm` cover it when the time comes; both flags are needed together, or the build waits forever at `READY_FOR_BETA_SUBMISSION`.

## One-time setup on the Mac

1. `brew install asc` (or `brew upgrade asc`) and check `asc --version` is 5.7.0 or later.
2. Create `~/.config/uponly/release.env` (outside the repository; never commit it):
   ```sh
   UPONLY_TEAM_ID=XXXXXXXXXX         # Tonkin Apps
   UPONLY_TESTER_EMAIL=you@example.com
   # The Tonkin Apps API key, with the Admin role (cloud signing needs it). Left out, Amora's
   # ~/.config/amora/asc.env, the same team's key, is used.
   # ASC_KEY_ID=...  ASC_ISSUER_ID=...  ASC_PRIVATE_KEY_PATH=~/.appstoreconnect/AuthKey_XXXX.p8
   ```
3. `scripts/ios_testflight.sh setup`, then add the `UPONLY_ASC_APP_ID=…` line it prints to `release.env`.

## Each build

```sh
git switch main && git pull
scripts/ios_testflight.sh upload                 # notes from ios/metadata/en-US/whats_new.txt
scripts/ios_testflight.sh upload notes.txt       # or your own What to Test
```

Apple processes the build for 5 to 30 minutes (`--wait` waits); it then appears in the TestFlight app for everyone in Internal. The version is the target's `MARKETING_VERSION`; raise it in the project for a new version.

## Keeping up with asc

`asc` ships several releases a week. Ask the binary rather than these notes: `asc --version`, `asc <command> --help`, `asc search "<what you want>"`. Features this flow relies on arrived in 5.6 (upload receipts with the build ID, What to Test normalisation, processing details when a wait fails) and 5.7 (`@file:` flag values, `ASC_READ_ONLY`, signer identity in `ipa-info`). After a major version, run `doctor` and read `asc <command> --help` for each command above before the next upload.

## Moving your data from the Mac

The phone keeps its own vault; there is no sync. To start from the Mac's data: on the Mac, **Manage → Security → Export encrypted backup**, put the backup folder in iCloud Drive or send it by AirDrop, then on the iPhone choose **Restore an encrypted backup…** at setup, with the Mac vault's recovery code.
