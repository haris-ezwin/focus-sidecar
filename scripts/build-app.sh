#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
app_dir="$project_dir/dist/Focus Sidecar.app"
contents_dir="$app_dir/Contents"
icon_source="$project_dir/Assets/AppIcon.png"
env_file="${FOCUS_SIDECAR_ENV_FILE:-$project_dir/.env}"

read_env_value() {
    local key="$1"
    sed -n "s/^${key}=//p" "$env_file" | tail -n 1 | tr -d '\r'
}

if [[ -f "$env_file" ]]; then
    : "${FOCUS_SUPABASE_URL:=$(read_env_value FOCUS_SUPABASE_URL)}"
    : "${FOCUS_SUPABASE_PUBLISHABLE_KEY:=$(read_env_value FOCUS_SUPABASE_PUBLISHABLE_KEY)}"
    : "${FOCUS_SUPABASE_TABLE:=$(read_env_value FOCUS_SUPABASE_TABLE)}"
fi

if [[ -z "${FOCUS_SUPABASE_URL:-}" || -z "${FOCUS_SUPABASE_PUBLISHABLE_KEY:-}" ]]; then
    print -u2 "Missing Supabase configuration. Copy .env.example to .env and fill it in."
    exit 1
fi

if [[ "$FOCUS_SUPABASE_PUBLISHABLE_KEY" == sb_secret_* ]]; then
    print -u2 "Refusing to embed a Supabase secret/service-role key. Use a publishable key."
    exit 1
fi

FOCUS_SUPABASE_TABLE="${FOCUS_SUPABASE_TABLE:-tasks}"

cd "$project_dir"
swift build -c release

mkdir -p "$contents_dir/MacOS" "$contents_dir/Resources"
cp "$project_dir/.build/release/FocusSidecar" "$contents_dir/MacOS/FocusSidecar"

if [[ -f "$icon_source" ]]; then
    icon_work_dir="$(mktemp -d "${TMPDIR:-/tmp}/focus-sidecar-icon.XXXXXX")"
    trap 'rm -rf "$icon_work_dir"' EXIT
    iconset_dir="$icon_work_dir/AppIcon.iconset"
    mkdir -p "$iconset_dir"

    sips -z 16 16 "$icon_source" --out "$iconset_dir/icon_16x16.png" >/dev/null
    sips -z 32 32 "$icon_source" --out "$iconset_dir/icon_16x16@2x.png" >/dev/null
    sips -z 32 32 "$icon_source" --out "$iconset_dir/icon_32x32.png" >/dev/null
    sips -z 64 64 "$icon_source" --out "$iconset_dir/icon_32x32@2x.png" >/dev/null
    sips -z 128 128 "$icon_source" --out "$iconset_dir/icon_128x128.png" >/dev/null
    sips -z 256 256 "$icon_source" --out "$iconset_dir/icon_128x128@2x.png" >/dev/null
    sips -z 256 256 "$icon_source" --out "$iconset_dir/icon_256x256.png" >/dev/null
    sips -z 512 512 "$icon_source" --out "$iconset_dir/icon_256x256@2x.png" >/dev/null
    sips -z 512 512 "$icon_source" --out "$iconset_dir/icon_512x512.png" >/dev/null
    sips -z 1024 1024 "$icon_source" --out "$iconset_dir/icon_512x512@2x.png" >/dev/null
    iconutil -c icns "$iconset_dir" -o "$contents_dir/Resources/AppIcon.icns"
fi

/usr/libexec/PlistBuddy -c "Clear dict" "$contents_dir/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :CFBundleDevelopmentRegion string en" "$contents_dir/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string FocusSidecar" "$contents_dir/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string com.ezwin.focus-sidecar" "$contents_dir/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleInfoDictionaryVersion string 6.0" "$contents_dir/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleName string Focus Sidecar" "$contents_dir/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundlePackageType string APPL" "$contents_dir/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string 0.3.0" "$contents_dir/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleVersion string 3" "$contents_dir/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$contents_dir/Info.plist"
/usr/libexec/PlistBuddy -c "Add :LSMinimumSystemVersion string 14.0" "$contents_dir/Info.plist"
/usr/libexec/PlistBuddy -c "Add :LSUIElement bool false" "$contents_dir/Info.plist"
/usr/libexec/PlistBuddy -c "Add :NSAccessibilityUsageDescription string Focus Sidecar follows the currently focused window." "$contents_dir/Info.plist"
/usr/libexec/PlistBuddy -c "Add :FocusSupabaseURL string $FOCUS_SUPABASE_URL" "$contents_dir/Info.plist"
/usr/libexec/PlistBuddy -c "Add :FocusSupabasePublishableKey string $FOCUS_SUPABASE_PUBLISHABLE_KEY" "$contents_dir/Info.plist"
/usr/libexec/PlistBuddy -c "Add :FocusSupabaseTable string $FOCUS_SUPABASE_TABLE" "$contents_dir/Info.plist"

codesign --force --deep --sign - "$app_dir"
echo "$app_dir"
