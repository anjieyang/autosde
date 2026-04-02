#!/usr/bin/env bash

set -euo pipefail

if ! command -v npm >/dev/null 2>&1; then
  echo "npm is required to install AutoSDE." >&2
  echo "Install Node.js from https://nodejs.org/" >&2
  exit 1
fi

npm install -g @anjieyang/autosde

echo
echo "Quick start:"
echo "  cd ~/my-project"
echo "  autosde"
