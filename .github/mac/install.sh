#!/bin/bash
# Puts the runner of Cartouche's CI on Ad's Mac (.github/mac/README.md). Run
# it in Terminal, from an administrator account, with the runner's
# registration token at hand (Settings › Actions › Runners › New
# self-hosted runner: the token of ./config.sh, valid an hour):
#
#     curl -fsSL https://raw.githubusercontent.com/clabeuhtegrite/Cartouche/COMMIT/.github/mac/install.sh -o /tmp/cartouche-ci.sh
#     sudo bash /tmp/cartouche-ci.sh COMMIT
#
# It takes its other files from the same COMMIT of the repository, or from
# its own folder when it runs from a checkout. It makes:
#
# - the account cartouche-ci: hidden, with no password, so that no one logs
#   in to it, with a group of its own, and refused the home of every other
#   account by an ACL; in _developer, for the simulators' UI tests;
# - the runner, at the version pinned below, in that account's home (it
#   updates itself afterwards, as GitHub's own do), registered to the
#   repository as ad-mac with the labels the jobs ask for (route.py): cartouche-mac,
#   xcode-<version> for each Xcode of /Applications, ios-sim-<version> for
#   each of them that runs every simulator of the screenshots;
# - root's folder /Library/CartoucheCI: the job hooks (job_started.py), the
#   supervisor (supervisor.py), cartouche-ci and config.json;
# - two LaunchDaemons: the supervisor, always on, and the runner, which the
#   supervisor starts and stops;
# - /usr/local/bin/cartouche-ci.
#
# When the Xcode the CI builds with cannot run the simulators of the
# screenshots (an iPad, the iPhone Duo), it offers to download them, about
# 8 GB a runtime; without them, only the app's builds come to the Mac. Run again, it
# updates the files and keeps the runner; when the labels would change, it
# asks for a new registration token, and without one keeps the runner as
# it was.

set -euo pipefail

REPOSITORY=clabeuhtegrite/Cartouche
OWNER=clabeuhtegrite
REF="${1:-main}"
ACCOUNT=cartouche-ci
NAME=ad-mac
SUPPORT=/Library/CartoucheCI
HOME_DIR="/Users/$ACCOUNT"
RUNNER="$HOME_DIR/runner"
WORK="$HOME_DIR/work.noindex"
# The build of the iOS 27.2 runtime made for the iPhone Duo
# (iOS-27-2-iPhone19-4), as GitHub's Macs have it (decision 20): Xcode
# 27.2's own iOS 27.2 runs no iPhone Duo.
DUO_RUNTIME=24B91016s
# The runner, and the SHA-256 its release gives for osx-arm64: no call to
# GitHub's API, which refuses an address after 60 an hour, can stop it.
RUNNER_VERSION=2.338.2
RUNNER_SHA=25a065af409ffa317ab4d5a3b614dd15fc9c40f2172bc1b35a1b1258e919a388
# What the account may not do in another account's home: anything.
ACL="user:$ACCOUNT deny list,search,add_file,add_subdirectory,delete_child,readattr,writeattr,readextattr,writeextattr,readsecurity,writesecurity,chown"
HERE="$(cd "$(dirname "$0")" && pwd)"
# The account's commands start in /, never in a folder it is refused (yours).
cd /

say() { printf '\n== %s\n' "$*"; }
fail() { printf '\n%s\n' "$*" >&2; exit 1; }
as_account() { sudo -u "$ACCOUNT" -H "$@"; }
as_admin() { sudo -u "$ADMIN" -H "$@"; }

# A file of the repository at REF: from this checkout, else from GitHub.
fetch() {
  if [[ "$HERE" == */.github/mac ]] && [ -f "$HERE/../../$1" ]; then
    cp "$HERE/../../$1" "$2"
  else
    curl -fsSL --retry 3 "https://raw.githubusercontent.com/$REPOSITORY/$REF/$1" -o "$2"
  fi
}

[ "$(id -u)" -eq 0 ] || fail "Run it with sudo: sudo bash $0 $REF"
ADMIN="${SUDO_USER:-}"
{ [ -n "$ADMIN" ] && [ "$ADMIN" != root ]; } || fail "Run it with sudo, from your own account."
[ "$(uname -m)" = arm64 ] || fail "This is not a Mac with Apple silicon."
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

say "Xcode"
XCODES=()
for app in /Applications/Xcode*.app; do
  [ -d "$app" ] || continue
  version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist" 2>/dev/null || true)"
  [ -n "$version" ] || continue
  echo "Xcode $version: $app"
  # One label for each version: the jobs take the first Xcode of it (job.sh).
  for line in ${XCODES[@]+"${XCODES[@]}"}; do
    [ "${line%% *}" != "$version" ] || continue 2
  done
  XCODES+=("$version $app")
done
[ "${#XCODES[@]}" -gt 0 ] || fail "No Xcode in /Applications: install Xcode first, from the App Store."
fetch .github/workflows/app.yml "$TMP/app.yml"
WANT="$(sed -n 's/^ *XCODE_VERSION: "\(.*\)"$/\1/p' "$TMP/app.yml" | head -n 1)"
WANT_APP=""
for line in "${XCODES[@]}"; do
  if [ "${line%% *}" = "$WANT" ]; then WANT_APP="${line#* }"; break; fi
done
if [ -z "$WANT_APP" ]; then
  echo "The CI builds with Xcode $WANT, which this Mac does not have: its jobs stay on GitHub's"
  echo "Macs until you install it in /Applications and run this again."
fi

say "iOS simulators"
fetch launcher/Gallery/scenarios.json "$TMP/scenarios.json"
fetch .github/mac/simulators.py "$TMP/simulators.py"
# What the screenshots need that the Xcode at $1 cannot run (simulators.py),
# empty when it runs them all. Asked as you: the runtimes are the Mac's.
missing_simulators() {
  { as_admin env DEVELOPER_DIR="$1/Contents/Developer" xcrun simctl list -j runtimes 2>/dev/null || true; } \
    | /usr/bin/python3 -I "$TMP/simulators.py" "$TMP/scenarios.json"
}
if [ -n "$WANT_APP" ]; then
  missing="$(missing_simulators "$WANT_APP")"
  if [ -n "$missing" ]; then
    echo "Xcode $WANT cannot run $missing, which the screenshots need."
    read -r -p "Download its iOS simulators now (about 8 GB a runtime)? [Y/n] " answer </dev/tty
    case "$answer" in
      n|N|no|non) echo "Not now: only the app's builds come to this Mac." ;;
      *)
        as_admin env DEVELOPER_DIR="$WANT_APP/Contents/Developer" xcodebuild -downloadPlatform iOS || true
        # The runtime made for the iPhone Duo, which GitHub's Macs have too.
        if [[ "$(missing_simulators "$WANT_APP")" == *"iPhone Duo"* ]]; then
          as_admin env DEVELOPER_DIR="$WANT_APP/Contents/Developer" \
            xcodebuild -downloadPlatform iOS -buildVersion "$DUO_RUNTIME" || true
        fi
        missing="$(missing_simulators "$WANT_APP")"
        [ -z "$missing" ] || echo "Xcode $WANT still cannot run $missing: add it in Xcode › Settings › Components, then run this again. Until then, only the app's builds come to this Mac."
        ;;
    esac
  fi
fi
LABELS="cartouche-mac"
for line in "${XCODES[@]}"; do
  version="${line%% *}"
  LABELS="$LABELS,xcode-$version"
  if [ -z "$(missing_simulators "${line#* }")" ]; then LABELS="$LABELS,ios-sim-$version"; fi
done
echo "Labels: $LABELS"

say "The account $ACCOUNT"
if ! dscl . -read "/Users/$ACCOUNT" UniqueID >/dev/null 2>&1; then
  gid=600
  while dscl . -list /Groups PrimaryGroupID | awk '{print $2}' | grep -qx "$gid"; do gid=$((gid + 1)); done
  uid=600
  while dscl . -list /Users UniqueID | awk '{print $2}' | grep -qx "$uid"; do uid=$((uid + 1)); done
  dscl . -create "/Groups/$ACCOUNT"
  dscl . -create "/Groups/$ACCOUNT" PrimaryGroupID "$gid"
  dscl . -create "/Groups/$ACCOUNT" RealName "Cartouche CI"
  dscl . -create "/Users/$ACCOUNT"
  dscl . -create "/Users/$ACCOUNT" UniqueID "$uid"
  dscl . -create "/Users/$ACCOUNT" PrimaryGroupID "$gid"
  dscl . -create "/Users/$ACCOUNT" UserShell /bin/zsh
  dscl . -create "/Users/$ACCOUNT" NFSHomeDirectory "$HOME_DIR"
  dscl . -create "/Users/$ACCOUNT" RealName "Cartouche CI"
  dscl . -create "/Users/$ACCOUNT" IsHidden 1
  dscl . -create "/Users/$ACCOUNT" Password '*'
  echo "Made, with the IDs $uid:$gid."
fi
mkdir -p "$HOME_DIR"
chown "$ACCOUNT:$ACCOUNT" "$HOME_DIR"
chmod 700 "$HOME_DIR"
as_account mkdir -p "$HOME_DIR/logs" "$WORK" "$HOME_DIR/DerivedData.noindex"
as_account defaults write com.apple.dt.Xcode IDECustomDerivedDataLocation -string "$HOME_DIR/DerivedData.noindex"
dseditgroup -o edit -a "$ACCOUNT" -t user _developer
DevToolsSecurity -enable >/dev/null
as_account /usr/bin/python3 -I -c 'import sys; print("Python", sys.version.split()[0], "for the hooks")'

# The account reads none of the other accounts' homes, even where macOS
# counts it in staff (through localaccounts), which most homes let in.
HOMES=()
while read -r user uid; do
  [ "$uid" -ge 500 ] && [ "$user" != "$ACCOUNT" ] || continue
  home="$(dscl . -read "/Users/$user" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
  [ -d "$home" ] && [[ "$home" == /Users/* ]] || continue
  acl="$(ls -led "$home")"
  [[ "$acl" == *"user:$ACCOUNT deny"* ]] || chmod +a "$ACL" "$home"
  if as_account ls "$home" >/dev/null 2>&1; then fail "$ACCOUNT still reads $home: stopped."; fi
  HOMES+=("$home")
  echo "$ACCOUNT is refused $home."
done < <(dscl . -list /Users UniqueID)

say "The runner"
if [ ! -x "$RUNNER/config.sh" ]; then
  curl -fsSL --retry 3 -o "$TMP/runner.tar.gz" \
    "https://github.com/actions/runner/releases/download/v$RUNNER_VERSION/actions-runner-osx-arm64-$RUNNER_VERSION.tar.gz"
  [ "$(shasum -a 256 "$TMP/runner.tar.gz" | cut -d ' ' -f 1)" = "$RUNNER_SHA" ] || fail "The runner's download has not the SHA-256 of its release."
  as_account mkdir -p "$RUNNER"
  # Through tar's input: the account cannot enter root's temporary folder
  # (/var/folders/zz/.../T, closed to every other account).
  as_account tar -xzf - -C "$RUNNER" <"$TMP/runner.tar.gz"
  echo "Runner $RUNNER_VERSION, in $RUNNER."
fi
REGISTERED="$(/usr/bin/python3 -I -c 'import json,sys; print(",".join(json.load(open(sys.argv[1])).get("labels", [])))' "$SUPPORT/config.json" 2>/dev/null || true)"
if [ ! -f "$RUNNER/.runner" ] || [ "$REGISTERED" != "$LABELS" ]; then
  [ -f "$RUNNER/.runner" ] && echo "The labels change, from $REGISTERED: the runner registers again."
  read -r -s -p "Registration token (Settings › Actions › Runners › New self-hosted runner): " TOKEN </dev/tty
  echo
  if [ -z "$TOKEN" ] && [ -f "$RUNNER/.runner" ]; then
    echo "No token: the runner keeps its labels."
    LABELS="$REGISTERED"
  else
    [ -n "$TOKEN" ] || fail "The runner needs a registration token."
    launchctl bootout system/fr.cartouche.ci.runner 2>/dev/null || true
    rm -f "$RUNNER/.runner" "$RUNNER/.credentials" "$RUNNER/.credentials_rsaparams"
    (cd "$RUNNER" && as_account ./config.sh --unattended --url "https://github.com/$REPOSITORY" --token "$TOKEN" \
      --name "$NAME" --labels "$LABELS" --work "$WORK" --replace)
  fi
fi
as_account cp "$RUNNER/bin/runsvc.sh" "$RUNNER/runsvc.sh"
as_account chmod 755 "$RUNNER/runsvc.sh"
# The jobs' PATH starts from the system's tools alone (job.sh adds the rest).
echo "/usr/bin:/bin:/usr/sbin:/sbin" | as_account tee "$RUNNER/.path" >/dev/null

say "Root's folder $SUPPORT"
mkdir -p "$SUPPORT" /Library/Logs/CartoucheCI
for file in job_started.py job-started.sh job-completed.sh supervisor.py cartouche-ci; do
  fetch ".github/mac/$file" "$SUPPORT/$file"
done
chown -R root:wheel "$SUPPORT"
chmod 755 "$SUPPORT" "$SUPPORT"/*.sh "$SUPPORT/cartouche-ci"
chmod 644 "$SUPPORT"/*.py
XCODE_LABELS="$(echo "$LABELS" | tr ',' '\n' | sed -n 's/^xcode-//p' | paste -sd ',' -)"
/usr/bin/python3 -I - "$SUPPORT/config.json" "$REPOSITORY" "$OWNER" "$LABELS" "$XCODE_LABELS" "$REF" ${HOMES[@]+"${HOMES[@]}"} <<'PY'
import json, sys
path, repository, owner, labels, xcode, ref, *homes = sys.argv[1:]
json.dump({"repository": repository, "owners": [owner], "labels": labels.split(","),
           "xcode": [v for v in xcode.split(",") if v], "homes": homes, "ref": ref},
          open(path, "w"), indent=2)
PY
chmod 644 "$SUPPORT/config.json"
mkdir -p /usr/local/bin
ln -sf "$SUPPORT/cartouche-ci" /usr/local/bin/cartouche-ci

say "The LaunchDaemons"
cat >/Library/LaunchDaemons/fr.cartouche.ci.runner.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>fr.cartouche.ci.runner</string>
  <key>UserName</key><string>$ACCOUNT</string>
  <key>GroupName</key><string>$ACCOUNT</string>
  <key>ProgramArguments</key><array><string>$RUNNER/runsvc.sh</string></array>
  <key>WorkingDirectory</key><string>$RUNNER</string>
  <key>EnvironmentVariables</key><dict>
    <key>ACTIONS_RUNNER_SVC</key><string>1</string>
    <key>ACTIONS_RUNNER_HOOK_JOB_STARTED</key><string>$SUPPORT/job-started.sh</string>
    <key>ACTIONS_RUNNER_HOOK_JOB_COMPLETED</key><string>$SUPPORT/job-completed.sh</string>
    <key>HOME</key><string>$HOME_DIR</string>
    <key>PATH</key><string>/usr/bin:/bin:/usr/sbin:/sbin</string>
    <key>LANG</key><string>en_US.UTF-8</string>
  </dict>
  <key>StandardOutPath</key><string>$HOME_DIR/logs/runner.log</string>
  <key>StandardErrorPath</key><string>$HOME_DIR/logs/runner.log</string>
  <key>SessionCreate</key><true/>
  <key>ProcessType</key><string>Standard</string>
  <key>Nice</key><integer>5</integer>
  <key>RunAtLoad</key><false/>
  <key>KeepAlive</key><false/>
  <key>ExitTimeOut</key><integer>60</integer>
</dict>
</plist>
PLIST
cat >/Library/LaunchDaemons/fr.cartouche.ci.supervisor.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>fr.cartouche.ci.supervisor</string>
  <key>ProgramArguments</key><array>
    <string>/usr/bin/python3</string><string>-I</string><string>$SUPPORT/supervisor.py</string>
  </array>
  <key>StandardErrorPath</key><string>/Library/Logs/CartoucheCI/supervisor.log</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>30</integer>
</dict>
</plist>
PLIST
for job in runner supervisor; do
  plist="/Library/LaunchDaemons/fr.cartouche.ci.$job.plist"
  chown root:wheel "$plist"
  chmod 644 "$plist"
  plutil -lint "$plist" >/dev/null
  launchctl bootout "system/fr.cartouche.ci.$job" 2>/dev/null || true
  launchctl bootstrap system "$plist"
done

say "Done"
/usr/bin/python3 -I "$SUPPORT/supervisor.py" once || true
for _ in $(seq 1 30); do
  grep -q "Listening for Jobs" "$HOME_DIR/logs/runner.log" 2>/dev/null && break
  sleep 2
done
cartouche-ci status
grep -q "Listening for Jobs" "$HOME_DIR/logs/runner.log" 2>/dev/null \
  && echo "The runner $NAME waits for jobs." \
  || echo "The runner $NAME is not online yet: cartouche-ci logs says why."
