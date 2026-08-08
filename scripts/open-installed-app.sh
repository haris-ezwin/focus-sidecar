#!/bin/zsh
set -euo pipefail

installed_app="${FOCUS_SIDECAR_APP_PATH:-${HOME}/Applications/Focus Sidecar.app}"

if [[ ! -d "$installed_app" ]]; then
    print -u2 "Focus Sidecar is not installed at: $installed_app"
    print -u2 "Build it with ./scripts/build-app.sh and copy it to ~/Applications first."
    exit 1
fi

open "$installed_app"
