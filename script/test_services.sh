#!/usr/bin/env bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$TASK_ROOT"
mkdir -p .build
xcrun swiftc -default-isolation MainActor HomeLink/Models/RemoteDevice.swift Tests/EndpointTests.swift -o .build/endpoint-tests
.build/endpoint-tests
xcrun swiftc HomeLink/Support/AuthorizationCommand.swift Tests/AuthorizationCommandTests.swift -o .build/authorization-command-tests
.build/authorization-command-tests
SOURCES=(HomeLink/Models/*.swift HomeLink/Services/*.swift HomeLink/Support/*.swift)
xcrun swiftc -default-isolation MainActor "${SOURCES[@]}" HomeLink/Stores/DeviceRepository.swift Tests/BackgroundServicesTests.swift -o .build/background-services-tests
.build/background-services-tests
xcrun swiftc -default-isolation MainActor HomeLink/Models/RemoteDevice.swift HomeLink/Support/BackgroundExecutor.swift HomeLink/Services/ProcessRunner.swift HomeLink/Services/KeyStore.swift Tests/KeyStoreTests.swift -o .build/keystore-tests
.build/keystore-tests
xcrun swiftc -default-isolation MainActor HomeLink/Models/RemoteDevice.swift HomeLink/Support/BackgroundExecutor.swift HomeLink/Services/SSHDiagnostics.swift Tests/SSHDiagnosticsTests.swift -o .build/ssh-diagnostics-tests
.build/ssh-diagnostics-tests
