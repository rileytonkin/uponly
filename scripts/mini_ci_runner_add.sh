#!/usr/bin/env bash
# mini_ci_runner_add.sh TOKEN: register Up Only's CI runner on the workhorse mini (workhorse-uponly, label uponly), a
# copy of an existing Amora runner's binaries, managed by launchd like the others. Modelled on Amora's
# scripts/loops/mini_ci_runner_add.sh.
#
# TOKEN is a runner registration token for this repository only; it expires in an hour. From the laptop:
#   TOKEN=$(gh api -X POST repos/rileytonkin/uponly/actions/runners/registration-token --jq .token)
#   ssh workhorse "bash -s -- $TOKEN" < scripts/mini_ci_runner_add.sh
# (or run it in a terminal on the mini). The repository is public: before registering, fork pull requests must need
# approval for all outside contributors (Settings, Actions, General), which .github/workflows/ci.yml relies on.
set -euo pipefail
[ "$(hostname -s)" = "workhorse" ] || { echo "not the workhorse; refusing"; exit 1; }
TOKEN="${1:?usage: mini_ci_runner_add.sh TOKEN}"
DIR="$HOME/actions-runner-uponly"; NAME="workhorse-uponly"; LABELS="uponly"
SRC=""
for candidate in "$HOME/actions-runner-ci-2" "$HOME/actions-runner"; do
  if [ -d "$candidate/bin" ]; then SRC="$candidate"; break; fi
done
[ -n "$SRC" ] || { echo "no existing runner folder to copy binaries from"; exit 2; }
if [ -f "$DIR/.runner" ]; then echo "$NAME already configured at $DIR"; exit 0; fi
# -L copies the real versioned folders, not links back into the source runner. A half-made folder is started over.
rm -rf "$DIR"; mkdir -p "$DIR"; cd "$DIR"
cp -RL "$SRC/bin" bin; cp -RL "$SRC/externals" externals; cp "$SRC"/*.sh .
./config.sh --url https://github.com/rileytonkin/uponly --token "$TOKEN" \
  --name "$NAME" --labels "$LABELS" --work _work --unattended --replace
# config.sh snapshots this shell's environment into .env; a non-login shell has no LANG, which some tools need.
grep -q '^LANG=' .env 2>/dev/null || echo "LANG=en_US.UTF-8" >> .env
./svc.sh install && ./svc.sh start
sleep 5
pgrep -f "$DIR/bin/Runner.Listener" >/dev/null && echo "$NAME: listener running" || { echo "$NAME: listener NOT running"; exit 1; }
