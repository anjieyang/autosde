#!/usr/bin/env bash

set -euo pipefail

INSTALL_DIR="${AUTOSDE_INSTALL_DIR:-$HOME/.local/bin}"
TARGET_PATH="$INSTALL_DIR/autosde"
DOWNLOAD_URL="${AUTOSDE_DOWNLOAD_URL:-https://raw.githubusercontent.com/anjieyang/autosde/main/loop.sh}"

if ! command -v curl >/dev/null 2>&1; then
  echo "curl is required to install AutoSDE." >&2
  exit 1
fi

mkdir -p "$INSTALL_DIR"
curl -fsSL "$DOWNLOAD_URL" -o "$TARGET_PATH"
chmod +x "$TARGET_PATH"

echo "Installed AutoSDE to $TARGET_PATH"

case ":$PATH:" in
  *":$INSTALL_DIR:"*)
    ;;
  *)
    echo
    echo "$INSTALL_DIR is not in your PATH."
    echo "Add this line to your shell profile, then open a new terminal:"
    echo "export PATH=\"$INSTALL_DIR:\$PATH\""
    ;;
esac

echo
echo "Quick start:"
echo "  cd ~/my-project"
echo "  autosde --github owner/repo"
