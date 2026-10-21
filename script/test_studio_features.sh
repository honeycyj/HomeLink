#!/usr/bin/env bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$TASK_ROOT"
mkdir -p .build
xcrun swiftc -default-isolation MainActor HomeLink/Models/*.swift HomeLink/Services/*.swift HomeLink/Support/*.swift HomeLink/Stores/DDNSStore.swift HomeLink/Stores/LocalAccessStore.swift Tests/StudioFeaturesTests.swift Tests/PublicIPDetectorTests.swift -o .build/studio-features-tests
.build/studio-features-tests
