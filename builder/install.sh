#!/bin/bash
# Installs Cartouche Builder on this Mac with the tools nxnative builds with,
# in one command, in Terminal:
#
#   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/clabeuhtegrite/Cartouche/main/builder/install.sh)"
#
# It installs Homebrew when the Mac has none, then with it Python 3.13 and
# its Tk, xcodegen, zstd and glslang; puts Cartouche Builder in
# ~/Applications, as an app that opens its window; readies Xcode (its iOS
# platform and Metal toolchain); has the builder download nxnative and make
# its Python environment; and opens Cartouche Builder. The nxnative it
# downloads builds without .NET (toolchain.py, needs_dotnet). Xcode itself
# comes from Apple, with its licence: when it is missing, or was never
# opened, the script opens it or its page and asks for the command again
# afterwards. Running it again updates Cartouche Builder and leaves its
# settings, its copy of nxnative and the games alone. It never downloads a
# game, a key or an IPA.
#
# CARTOUCHE_REF=<branch> installs the builder of another branch.

set -euo pipefail

REPOSITORY="clabeuhtegrite/Cartouche"
REF="${CARTOUCHE_REF:-main}"
APP="$HOME/Applications/Cartouche Builder.app"
BREW=/opt/homebrew/bin/brew
PYTHON=/opt/homebrew/bin/python3.13
# What toolchain.py's doctor asks Homebrew for, with the Tk the window needs.
FORMULAE=(python@3.13 python-tk@3.13 xcodegen zstd glslang)
# The Xcode nxnative's shaders are locked with (toolchain.py).
XCODE_VERSION=27.2
XCODE_APP_STORE="macappstore://apps.apple.com/app/xcode/id497799835"

# In the Mac's language, French or English.
french=false
case "$(defaults read -g AppleLanguages 2>/dev/null | tr -d ' \n"()' | cut -d, -f1)" in
  fr*) french=true ;;
esac

say() { # say ENGLISH FRENCH
  if $french; then printf '%s\n' "$2"; else printf '%s\n' "$1"; fi
}
step() { printf '\n\033[1m==> %s\033[0m\n' "$(say "$1" "$2")"; }
fail() {
  printf '\n\033[1;31m%s\033[0m\n' "$(say "$1" "$2")" >&2
  exit 1
}

# ---- This Mac

step "Checking this Mac" "Vérification de ce Mac"
[ "$(uname -s)" = Darwin ] || fail "Cartouche Builder runs on a Mac." "Cartouche Builder fonctionne sur un Mac."
[ "$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)" = 1 ] ||
  fail "nxnative builds on a Mac with Apple silicon (M1 or later)." \
       "nxnative construit sur un Mac à puce Apple (M1 ou plus récent)."
[ "$(uname -m)" = arm64 ] ||
  fail "This Terminal runs under Rosetta. Open Terminal without it (Get Info, untick Open using Rosetta) and run the command again." \
       "Ce Terminal tourne sous Rosetta. Ouvrez Terminal sans lui (Lire les informations, décochez Ouvrir avec Rosetta) et relancez la commande."
macos=$(sw_vers -productVersion)
major=${macos%%.*}
minor=0
case "$macos" in
  *.*) minor=${macos#*.}; minor=${minor%%.*} ;;
esac
if [ "$major" -lt 26 ] || { [ "$major" -eq 26 ] && [ "$minor" -lt 6 ]; }; then
  fail "nxnative builds on macOS 26.6 or later, and this Mac has macOS $macos. Update it in System Settings › General › Software Update, then run the command again." \
       "nxnative construit sous macOS 26.6 ou ultérieur, et ce Mac a macOS $macos. Mettez-le à jour dans Réglages Système › Général › Mise à jour de logiciels, puis relancez la commande."
fi
say "macOS $macos, Apple silicon." "macOS $macos, puce Apple."

# ---- Homebrew and its tools

step "Homebrew" "Homebrew"
if [ ! -x "$BREW" ]; then
  say "Homebrew installs the tools nxnative needs. It asks for this Mac's password, and may first install Apple's command line tools." \
      "Homebrew installe les outils dont nxnative a besoin. Il demande le mot de passe de ce Mac, et peut d’abord installer les outils en ligne de commande d’Apple."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi
[ -x "$BREW" ] || fail "Homebrew did not install. Run the command again." "Homebrew ne s’est pas installé. Relancez la commande."
eval "$("$BREW" shellenv)"
export HOMEBREW_NO_ENV_HINTS=1
# Terminal finds Homebrew from now on, as Homebrew asks, for the commands
# the builder's Mac tools… may open there.
if ! grep -qs 'brew shellenv' "$HOME/.zprofile"; then
  # shellcheck disable=SC2016 # written as is, for zsh to run
  printf '\neval "$(%s shellenv)"\n' "$BREW" >>"$HOME/.zprofile"
fi

step "Python with Tk, xcodegen, zstd and glslang" "Python avec Tk, xcodegen, zstd et glslang"
brew install "${FORMULAE[@]}"

# ---- Cartouche Builder

step "Cartouche Builder" "Cartouche Builder"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
source=""
if curl -fsSL "https://github.com/$REPOSITORY/archive/refs/heads/$REF.tar.gz" | tar -xzf - -C "$work"; then
  source=$(find "$work" -mindepth 2 -maxdepth 2 -type d -name builder | head -n 1)
fi
if [ -z "$source" ] || [ ! -d "$source/cartouche_builder" ]; then
  fail "Cartouche Builder could not be downloaded. Check the connection and run the command again." \
       "Cartouche Builder n’a pas pu être téléchargé. Vérifiez la connexion et relancez la commande."
fi
version=$(sed -n 's/^version = "\(.*\)"$/\1/p' "$source/pyproject.toml")

bundle="$work/Cartouche Builder.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp -R "$source/cartouche_builder" "$bundle/Contents/Resources/"
find "$bundle/Contents/Resources" -name __pycache__ -type d -prune -exec rm -rf {} +
cat >"$bundle/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDisplayName</key>
  <string>Cartouche Builder</string>
  <key>CFBundleExecutable</key>
  <string>Cartouche Builder</string>
  <key>CFBundleIdentifier</key>
  <string>io.github.clabeuhtegrite.cartouche-builder</string>
  <key>CFBundleName</key>
  <string>Cartouche Builder</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${version:-0}</string>
  <key>LSMinimumSystemVersion</key>
  <string>26.6</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST
# The app's program: the window, as "Cartouche Builder.command" opens it,
# with a Python 3.12 or later that has Tk.
cat >"$bundle/Contents/MacOS/Cartouche Builder" <<'LAUNCHER'
#!/bin/sh
here=$(cd "$(dirname "$0")/../Resources" && pwd) || exit 1
PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
export PATH
# Older versions of macOS pass the app a process serial number.
for argument do
  shift
  case $argument in -psn_*) ;; *) set -- "$@" "$argument" ;; esac
done
for candidate in python3.14 python3.13 python3.12 python3; do
  python=$(command -v "$candidate" 2>/dev/null) || continue
  if "$python" -c 'import sys, tkinter; sys.exit(sys.version_info < (3, 12))' 2>/dev/null; then
    cd "$here" || exit 1
    PYTHONPATH="$here" exec "$python" -m cartouche_builder "$@"
  fi
done
osascript -e 'display alert "Cartouche Builder needs Python 3.12 or later with Tk." message "In Terminal: brew install python@3.13 python-tk@3.13"' >/dev/null 2>&1
exit 1
LAUNCHER
chmod 755 "$bundle/Contents/MacOS/Cartouche Builder"
mkdir -p "$HOME/Applications"
rm -rf "$APP"
mv "$bundle" "$APP"
say "Installed: $APP" "Installé : $APP"

# ---- Xcode

step "Xcode $XCODE_VERSION" "Xcode $XCODE_VERSION"
xcode=""
if developer=$(xcode-select -p 2>/dev/null) && [ -d "$developer/Platforms" ]; then
  xcode=${developer%/Contents/Developer}
else
  for candidate in "/Applications/Xcode-$XCODE_VERSION.app" /Applications/Xcode.app /Applications/Xcode*.app; do
    if [ -d "$candidate/Contents/Developer" ]; then
      say "Cartouche Builder selects $candidate: this Mac's password, once." \
          "Cartouche Builder sélectionne $candidate : le mot de passe de ce Mac, une fois."
      sudo xcode-select -s "$candidate/Contents/Developer"
      xcode=$candidate
      break
    fi
  done
fi
ready=true
if [ -z "$xcode" ]; then
  ready=false
  say "Xcode is missing. Install Xcode $XCODE_VERSION, free from Apple: its App Store page opens. Open it once, agree to its licence and tick iOS among its platforms, then run this command again." \
      "Xcode manque. Installez Xcode $XCODE_VERSION, gratuit chez Apple : sa page de l’App Store s’ouvre. Ouvrez-le une fois, acceptez sa licence et cochez iOS parmi ses plateformes, puis relancez cette commande."
  open "$XCODE_APP_STORE" || true
elif ! xcodebuild -checkFirstLaunchStatus >/dev/null 2>&1; then
  ready=false
  say "Xcode opens: agree to its licence and tick iOS among its platforms, then run this command again." \
      "Xcode s’ouvre : acceptez sa licence et cochez iOS parmi ses plateformes, puis relancez cette commande."
  open -a "$xcode" || true
else
  found=$(xcodebuild -version 2>/dev/null | sed -n 's/^Xcode //p' || true)
  say "Xcode $found, at $xcode." "Xcode $found, dans $xcode."
  if [ "$found" != "$XCODE_VERSION" ]; then
    say "nxnative's shaders are built with Xcode $XCODE_VERSION: Mac tools… in Cartouche Builder says whether this one will do." \
        "Les shaders de nxnative se construisent avec Xcode $XCODE_VERSION : Outils du Mac… dans Cartouche Builder dit si celui-ci convient."
  fi
  # As toolchain.py checks them, and as its Mac tools… would fix them.
  if ! xcrun --sdk iphoneos --show-sdk-version >/dev/null 2>&1; then
    say "Downloading Xcode's iOS platform, a few gigabytes…" "Téléchargement de la plateforme iOS de Xcode, quelques gigaoctets…"
    xcodebuild -downloadPlatform iOS || ready=false
  fi
  if ! xcrun -sdk iphoneos metal --version >/dev/null 2>&1; then
    say "Downloading Xcode's Metal toolchain…" "Téléchargement de la Metal toolchain de Xcode…"
    xcodebuild -downloadComponent MetalToolchain || ready=false
  fi
fi

# ---- nxnative and the first start

if $ready; then
  step "nxnative and its Python environment" "nxnative et son environnement Python"
  # Then the builder's own check of the Mac's tools.
  if ! (cd "$APP/Contents/Resources" && PYTHONPATH="$APP/Contents/Resources" "$PYTHON" -m cartouche_builder setup); then
    say "Mac tools… in Cartouche Builder shows what is left to do." \
        "Outils du Mac… dans Cartouche Builder montre ce qui reste à faire."
  fi
  step "Done" "Terminé"
  say "Cartouche Builder is in the Applications folder of your home, and opens now. Choose your game sources, your games folder and prod.keys there, then build." \
      "Cartouche Builder est dans le dossier Applications de votre dossier personnel, et s’ouvre maintenant. Choisissez-y les sources de vos jeux, votre dossier des jeux et prod.keys, puis construisez."
  open "$APP"
else
  step "Almost done" "Presque terminé"
  say "Cartouche Builder is installed. Once Xcode is ready, run the same command again: it picks up from there." \
      "Cartouche Builder est installé. Une fois Xcode prêt, relancez la même commande : elle reprend là."
  exit 1
fi
