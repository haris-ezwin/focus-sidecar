#!/bin/zsh
set -euo pipefail
focus_project_dir="${0:A:h:h}"
focus_test_dir="$(mktemp -d "${TMPDIR:-/tmp}/focus-usage-tests.XXXXXX")"
trap 'rm -rf "$focus_test_dir"' EXIT
cd "$focus_project_dir"
swiftc -parse-as-library \
    Sources/FocusSidecar/CodexUsageHistory.swift \
    Sources/FocusSidecar/CodexUsageClient.swift \
    Tests/FocusSidecarTests/CodexUsageTests.swift \
    -o "$focus_test_dir/codex-usage-tests"
"$focus_test_dir/codex-usage-tests"
