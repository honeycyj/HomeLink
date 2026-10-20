#!/usr/bin/env bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$TASK_ROOT"
mkdir -p .build
SOURCES=(HomeLink/Models/*.swift HomeLink/Services/*.swift HomeLink/Support/*.swift)
xcrun swiftc -default-isolation MainActor "${SOURCES[@]}" HomeLink/Stores/ConnectionController.swift HomeLink/Stores/DeviceRepository.swift Tests/ConnectionLifecycleTests.swift -o .build/connection-lifecycle-tests
.build/connection-lifecycle-tests
xcrun swiftc HomeLink/Support/SSHProcessSupervisor.swift Tests/SSHParentDeathProbe.swift -o .build/ssh-parent-death-probe
xcrun swiftc -default-isolation MainActor "${SOURCES[@]}" HomeLink/Stores/ConnectionController.swift Tests/SSHProcessLifecycleTests.swift -o .build/ssh-process-lifecycle-tests
.build/ssh-process-lifecycle-tests "$TASK_ROOT/.build/ssh-parent-death-probe"
