#!/usr/bin/env bash
# MeridianBar installer — https://github.com/Jean-Reinhold/meridian-bar
#
#   curl -fsSL https://raw.githubusercontent.com/Jean-Reinhold/meridian-bar/main/install.sh | bash
#
# Flags:
#   --version vX.Y.Z   install a specific release (default: latest)
#   --from-source      clone and build locally (needs Command Line Tools)
#   --uninstall        quit and remove the app
#
# The app is ad-hoc signed, not Apple-notarized (a deliberate project
# decision — see okf/06-release.md). This script verifies the release
# sha256 and strips the quarantine attribute so the app opens cleanly.

set -euo pipefail

REPO="Jean-Reinhold/meridian-bar"
APP_NAME="MeridianBar"
VERSION=""
MODE="release"

for arg in "$@"; do
  case "$arg" in
    --version) MODE="release" ;;
    v*.*.*) VERSION="$arg" ;;
    --from-source) MODE="source" ;;
    --uninstall) MODE="uninstall" ;;
    --help|-h)
      sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "unknown flag: $arg (try --help)" >&2; exit 2 ;;
  esac
done

fail() { echo "error: $*" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || fail "MeridianBar is a macOS app."

dest_dir() {
  if [ -w /Applications ]; then echo /Applications; else
    mkdir -p "$HOME/Applications"; echo "$HOME/Applications"
  fi
}

quit_app() { osascript -e "quit app \"$APP_NAME\"" >/dev/null 2>&1 || true; }

if [ "$MODE" = "uninstall" ]; then
  quit_app
  removed=0
  for dir in /Applications "$HOME/Applications"; do
    if [ -d "$dir/$APP_NAME.app" ]; then rm -rf "$dir/$APP_NAME.app"; removed=1; fi
  done
  defaults delete com.jeanreinhold.MeridianBar >/dev/null 2>&1 || true
  [ "$removed" = 1 ] && echo "$APP_NAME removed." || echo "$APP_NAME was not installed."
  exit 0
fi

install_bundle() { # $1 = path to MeridianBar.app
  local dest; dest="$(dest_dir)"
  quit_app
  rm -rf "${dest:?}/$APP_NAME.app"
  cp -R "$1" "$dest/$APP_NAME.app"
  xattr -dr com.apple.quarantine "$dest/$APP_NAME.app" 2>/dev/null || true
  open "$dest/$APP_NAME.app"
  echo "Installed $APP_NAME to $dest and launched it."
  echo "It lives in the menu bar — look for the per-account usage segments."
}

if [ "$MODE" = "source" ]; then
  xcode-select -p >/dev/null 2>&1 || fail "building from source needs Command Line Tools: xcode-select --install"
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
  echo "Cloning $REPO…"
  git clone --quiet --depth 1 "https://github.com/$REPO.git" "$tmp/src"
  echo "Building (swift build -c release)…"
  make -C "$tmp/src" app
  install_bundle "$tmp/src/dist/$APP_NAME.app"
  exit 0
fi

# Release install
api="https://api.github.com/repos/$REPO/releases"
if [ -n "$VERSION" ]; then api="$api/tags/$VERSION"; else api="$api/latest"; fi

json="$(curl -fsSL "$api" 2>/dev/null)" || {
  echo "No published release found." >&2
  echo "Until the first release ships, install from source instead:" >&2
  echo "  curl -fsSL https://raw.githubusercontent.com/$REPO/main/install.sh | bash -s -- --from-source" >&2
  exit 1
}

zip_url="$(printf '%s' "$json" | grep -o '"browser_download_url": *"[^"]*\.zip"' | head -1 | cut -d'"' -f4)"
sha_url="$(printf '%s' "$json" | grep -o '"browser_download_url": *"[^"]*\.sha256"' | head -1 | cut -d'"' -f4)"
[ -n "$zip_url" ] || fail "release has no .zip asset"

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
echo "Downloading ${zip_url##*/}…"
curl -fsSL -o "$tmp/app.zip" "$zip_url"

if [ -n "$sha_url" ]; then
  curl -fsSL -o "$tmp/app.zip.sha256" "$sha_url"
  expected="$(awk '{print $1}' "$tmp/app.zip.sha256")"
  actual="$(shasum -a 256 "$tmp/app.zip" | awk '{print $1}')"
  [ "$expected" = "$actual" ] || fail "sha256 mismatch: expected $expected, got $actual"
  echo "sha256 verified."
else
  echo "warning: release has no .sha256 asset; skipping checksum verification" >&2
fi

ditto -x -k "$tmp/app.zip" "$tmp/unzipped"
bundle="$(find "$tmp/unzipped" -maxdepth 2 -name "$APP_NAME.app" | head -1)"
[ -n "$bundle" ] || fail "no $APP_NAME.app inside the release zip"
install_bundle "$bundle"
