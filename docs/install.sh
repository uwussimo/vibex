#!/bin/sh
# Vibex installer: downloads the latest release, verifies it, and installs Vibex.app.
#   curl -fsSL https://uwussimo.github.io/vibex/install.sh | sh
#
# Files fetched with curl are not quarantined, so macOS does not block the un-notarized app.
# Options (environment variables):
#   VIBEX_VERSION=1.0.0      install a specific version instead of the latest
#   VIBEX_INSTALL_DIR=...    install somewhere other than /Applications
#   VIBEX_NO_OPEN=1          do not launch Vibex afterwards
#   VIBEX_NO_CLI=1           do not link the vibex command
set -eu

REPO="uwussimo/vibex"
APP_NAME="Vibex.app"

say() { printf '\033[1;32m==>\033[0m %s\n' "$1"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$1" >&2; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$1" >&2; exit 1; }

# --- Checks ---------------------------------------------------------------
[ "$(uname -s)" = "Darwin" ] || die "Vibex is a macOS app."
[ "$(uname -m)" = "arm64" ] || die "Vibex needs a Mac with Apple silicon."
major=$(sw_vers -productVersion | cut -d. -f1)
[ "$major" -ge 26 ] || die "Vibex needs macOS 26 or later (this Mac runs $(sw_vers -productVersion))."
command -v curl >/dev/null || die "curl is required."

# --- Find the release ------------------------------------------------------
if [ -n "${VIBEX_VERSION:-}" ]; then
  api="https://api.github.com/repos/$REPO/releases/tags/v$VIBEX_VERSION"
else
  api="https://api.github.com/repos/$REPO/releases/latest"
fi
say "Looking up the release"
release=$(curl -fsSL -H "Accept: application/vnd.github+json" "$api") || die "Could not reach GitHub ($api)."
dmg_url=$(printf '%s' "$release" | grep -o '"browser_download_url": *"[^"]*\.dmg"' | head -1 | sed 's/.*"\(https[^"]*\)"/\1/')
sum_url=$(printf '%s' "$release" | grep -o '"browser_download_url": *"[^"]*\.dmg\.sha256"' | head -1 | sed 's/.*"\(https[^"]*\)"/\1/')
[ -n "$dmg_url" ] || die "No DMG found in the release."
version=$(printf '%s' "$release" | grep -o '"tag_name": *"[^"]*"' | head -1 | sed 's/.*"v\{0,1\}\([^"]*\)"$/\1/')

# --- Download and verify ---------------------------------------------------
tmp=$(mktemp -d)
mount="$tmp/mount"
cleanup() {
  hdiutil detach "$mount" -quiet >/dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap cleanup EXIT INT TERM

say "Downloading Vibex $version"
curl -fL --progress-bar "$dmg_url" -o "$tmp/Vibex.dmg" || die "Download failed."
if [ -n "$sum_url" ]; then
  expected=$(curl -fsSL "$sum_url" | awk '{print $1}')
  actual=$(shasum -a 256 "$tmp/Vibex.dmg" | awk '{print $1}')
  [ "$expected" = "$actual" ] || die "Checksum mismatch (expected $expected, got $actual)."
  say "Checksum verified"
else
  warn "The release has no checksum file; skipping verification."
fi

# --- Install -----------------------------------------------------------------
dest_dir=${VIBEX_INSTALL_DIR:-/Applications}
if [ ! -w "$dest_dir" ]; then
  if [ -z "${VIBEX_INSTALL_DIR:-}" ]; then
    dest_dir="$HOME/Applications"
    mkdir -p "$dest_dir"
    warn "/Applications is not writable; installing to $dest_dir"
  else
    die "$dest_dir is not writable."
  fi
fi
dest="$dest_dir/$APP_NAME"

mkdir -p "$mount"
hdiutil attach "$tmp/Vibex.dmg" -nobrowse -readonly -quiet -mountpoint "$mount" || die "Could not open the DMG."
[ -d "$mount/$APP_NAME" ] || die "The DMG does not contain $APP_NAME."

if [ -z "${VIBEX_INSTALL_DIR:-}" ] && pgrep -x Vibex >/dev/null 2>&1; then
  say "Quitting the running Vibex (your windows come back on relaunch)"
  osascript -e 'tell application "Vibex" to quit' >/dev/null 2>&1 || true
  i=0
  while pgrep -x Vibex >/dev/null 2>&1 && [ $i -lt 20 ]; do sleep 0.5; i=$((i + 1)); done
fi

say "Installing to $dest"
rm -rf "$dest"
ditto "$mount/$APP_NAME" "$dest"
xattr -dr com.apple.quarantine "$dest" 2>/dev/null || true

# --- The vibex command ----------------------------------------------------------
# Links `vibex` (like VS Code's `code`) into the first writable folder on PATH, never replacing another file.
link_cli() {
  cli="$dest/Contents/Resources/vibex"
  [ -x "$cli" ] || return 0
  for dir in /opt/homebrew/bin /usr/local/bin "$HOME/.local/bin" "$HOME/bin"; do
    case ":$PATH:" in *":$dir:"*) ;; *) continue ;; esac
    [ -d "$dir" ] && [ -w "$dir" ] || continue
    if [ -e "$dir/vibex" ] && [ ! -L "$dir/vibex" ]; then
      warn "$dir/vibex already exists; not replacing it."
      return 0
    fi
    ln -sf "$cli" "$dir/vibex"
    say "Linked the vibex command: $dir/vibex (run 'vibex .' in a project folder)"
    return 0
  done
  warn "No writable folder on PATH for the vibex command. Use Vibex → Install 'vibex' Command."
}
[ -n "${VIBEX_NO_CLI:-}" ] || link_cli

# --- What else is needed ------------------------------------------------------
dev_dir=$(xcode-select -p 2>/dev/null || true)
case "$dev_dir" in
  *Xcode*.app/Contents/Developer) ;;
  *) warn "Xcode 26 was not found. Vibex needs it (with an iOS simulator runtime) for the simulator pane." ;;
esac
command -v claude >/dev/null 2>&1 || warn "Claude Code is not installed. Get it with: npm install -g @anthropic-ai/claude-code"

say "Vibex $version is installed."
if [ -z "${VIBEX_NO_OPEN:-}" ]; then
  open "$dest"
fi
