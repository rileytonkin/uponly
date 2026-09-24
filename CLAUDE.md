# Up Only — agent notes

## After every merge to `main`: install the new build on the owner's Mac

Whenever you merge a PR into `main` that changes the app (`UpOnly/`, `Tests/` or `UpOnly.xcodeproj/`), install the merged build on the owner's Mac before reporting back. From a cloud workspace, use the local-command tool to run these steps on the Mac.

1. Back up the vault and the installed app (both stay encrypted/unchanged):
   ```sh
   B=~/Library/Application\ Support/Up\ Only\ Migration\ Backups/<short-name>-$(date +%Y%m%d-%H%M%S)
   mkdir -p "$B"
   ditto ~/Library/Containers/org.uponly.personal/Data/Library/Application\ Support/Up\ Only\ Personal "$B/Up Only Personal"
   ditto "/Applications/Up Only.app" "$B/Previous Up Only.app"
   ```
2. Build and install with the owner's local script, which pulls `main`, builds the private (`UPONLY_PERSONAL`, `org.uponly.personal`) Release, quits the running app, installs to `/Applications` and relaunches it:
   ```sh
   ~/Developer/Up\ Only/build-personal.sh
   ```
   The script is local to the Mac and not in the repo: it holds the signing team. If it fails to compile, fix it on a branch, merge, and install again. The public fixture build doesn't compile the `UPONLY_PERSONAL` code paths, so this is the only check of the private build.
3. Confirm `/Applications/Up Only.app` is running and has no new crash report in `~/Library/Logs/DiagnosticReports`. Tell the owner the build time and where the backup is.

Keep everything in the background: never take the owner's cursor or focus. The app quits and relaunches only during the install.
