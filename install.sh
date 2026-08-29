#!/usr/bin/env bash
# Build and install Quickshell for macOS. Safe to re-run.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
ROOT="$(pwd)"

say() { printf '\n\033[1;36m==>\033[0m %s\n' "$1"; }

[ "$(uname -s)" = "Darwin" ] || { echo "macOS only — upstream Quickshell covers Linux." >&2; exit 1; }
command -v brew >/dev/null || { echo "Install Homebrew first: https://brew.sh" >&2; exit 1; }

say "Build dependencies"
brew install --quiet qt cmake ninja pkgconf

say "Runtime dependencies"
# What the bin/qs-* launchers shell out to.
brew install --quiet jq media-control switchaudio-osx
# Night Shift for the hyprsunset stand-in (bin/hyprsunset --temperature).
brew install --quiet smudge/smudge/nightlight

# matugen generates the Material palette; not in core brew.
command -v matugen >/dev/null || \
  echo "  note: matugen not found — 'qs-matugen' needs it (cargo install matugen)"

say "Building"
bin/qs-build

say "Shell config"
if [ -e "$HOME/.config/quickshell" ]; then
  echo "  ~/.config/quickshell already exists, leaving it alone"
else
  echo "  no shell config found — clone one:"
  echo "    git clone https://github.com/minimal-05/darwin-dotfiles.git ~/.config"
fi

# The launchers are referenced by absolute path from karabiner.json and skhdrc.
say "Done"
cat <<EOF

  Binary:    $ROOT/bin/quickshell
  Launchers: $ROOT/bin/qs-*

  Start it:  $ROOT/bin/qs-switch mine

  If you keep this repo somewhere other than ~/Projects/quickshell-macos,
  update the absolute paths in ~/.config/karabiner/karabiner.json and
  ~/.config/skhd/skhdrc — they call bin/qs-ipc directly.
EOF
