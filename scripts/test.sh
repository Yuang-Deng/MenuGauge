#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p .build
swiftc Sources/StatusRing/Models.swift Sources/StatusRing/TemperaturePreferences.swift Sources/StatusRing/RingRenderer.swift Sources/StatusRing/NetworkReader.swift Sources/StatusRing/ExitCountry.swift Sources/StatusRing/CodexAppServer.swift Sources/StatusRing/CodexQuota.swift Sources/StatusRing/SmartCharging.swift Sources/StatusRing/ResourceReader.swift Sources/StatusRing/PressureLevel.swift Sources/StatusRing/DiskReader.swift Sources/StatusRing/EyeReminder.swift Sources/StatusRing/UsageBar.swift Sources/StatusRing/HolidayCountdown.swift Sources/StatusRing/HolidaySidePanel.swift Tests/StatusRingTests/AppearanceChecks.swift Tests/StatusRingTests/StatusRingTests.swift -o .build/status-ring-checks
.build/status-ring-checks
