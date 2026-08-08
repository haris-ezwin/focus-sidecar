#!/bin/zsh
set -euo pipefail

focus_project_dir="${0:A:h:h}"
focus_installed_app="${FOCUS_SIDECAR_APP_PATH:-${HOME}/Applications/Focus Sidecar.app}"
focus_lsregister="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

cd "$focus_project_dir"
./scripts/build-app.sh

if pgrep -x FocusSidecar >/dev/null; then
    pkill -x FocusSidecar
fi

mkdir -p "${focus_installed_app:h}"
ditto "dist/Focus Sidecar.app" "$focus_installed_app"
codesign --verify --deep --strict "$focus_installed_app"
"$focus_lsregister" -f "$focus_installed_app"
open "$focus_installed_app"

print "Focus Sidecar is updated and open."
