#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p .build
swiftc Sources/StatusRing/Models.swift Sources/StatusRing/TemperaturePreferences.swift Sources/StatusRing/RingRenderer.swift Sources/StatusRing/NetworkReader.swift Sources/StatusRing/ExitCountry.swift Sources/StatusRing/CodexAppServer.swift Sources/StatusRing/CodexQuota.swift Sources/StatusRing/Fingerprint.swift Sources/StatusRing/ModelIntegrity.swift Sources/StatusRing/SmartCharging.swift Sources/StatusRing/ResourceReader.swift Sources/StatusRing/PressureLevel.swift Sources/StatusRing/DiskReader.swift Tests/StatusRingTests/AppearanceChecks.swift Tests/StatusRingTests/FingerprintChecks.swift Tests/StatusRingTests/ModelRPCChecks.swift Tests/StatusRingTests/StatusRingTests.swift -o .build/model-checks
.build/model-checks
