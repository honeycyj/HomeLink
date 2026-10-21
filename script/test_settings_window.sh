#!/usr/bin/env bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$TASK_ROOT"
mkdir -p .build
xcrun swiftc -default-isolation MainActor HomeLink/Views/Components/SettingsWindowControls.swift Tests/SettingsWindowControlsTests.swift -o .build/settings-window-tests
.build/settings-window-tests
