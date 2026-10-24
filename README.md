# RMM Automation Scripts

[![CI](https://github.com/ich74851-doom/rmm-automation-scripts/actions/workflows/ci.yml/badge.svg)](https://github.com/ich74851-doom/rmm-automation-scripts/actions/workflows/ci.yml)
![PowerShell](https://img.shields.io/badge/PowerShell-5.1%20%7C%207%2B-5391FE?logo=powershell&logoColor=white)
![RMM](https://img.shields.io/badge/RMM-NinjaOne%20%7C%20Syncro%20%7C%20Datto%20%7C%20ConnectWise-555555)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

## Overview

These are vendor-neutral PowerShell scripts for monitoring and remediating Windows endpoints. They
run unchanged on NinjaOne (NinjaRMM), Syncro, Datto RMM and ConnectWise RMM/Automate. Every
script follows the same [exit-code and output convention](docs/exit-codes.md), so one alert
policy works for all of them, and every script is self-contained, so it can be uploaded to an
RMM on its own.

These scripts reflect the kind of patching, monitoring and remediation work I do across client
fleets with RMM tools. They are written from scratch for this repository and contain no client
data.

## Features

| Script | What it does | Exit codes |
|---|---|---|
| [`Get-PendingRebootStatus.ps1`](scripts/Get-PendingRebootStatus.ps1) | Detects a pending reboot (CBS, Windows Update, file renames, computer rename, ConfigMgr) and reports why. Detection only. | 0 none · 1 pending · 3 not Windows |
| [`Get-WindowsUpdateStatus.ps1`](scripts/Get-WindowsUpdateStatus.ps1) | Lists missing updates through the Windows Update Agent API and checks security-update count and last-install age against thresholds. | 0 compliant · 1 non-compliant · 2 search failed · 3 API unavailable |
| [`Invoke-DiskCleanup.ps1`](scripts/Invoke-DiskCleanup.ps1) | Removes old files from temp folders, the Windows Update download cache and CBS cabinets. Supports `-WhatIf`, logs space freed and checks a free-space target. | 0 OK · 1 still low · 2 error |
| [`Restart-ServiceWithLogging.ps1`](scripts/Restart-ServiceWithLogging.ps1) | Starts or restarts a service with retries, timeouts and logging, and handles disabled services. | 0 running · 1 disabled · 2 failed |

Common to all scripts:

- Consistent `RESULT: <status> (exit <code>) - <summary>` final line and timestamped log lines
- Optional `-LogPath` file logging
- `-WhatIf` on everything that changes state
- Windows PowerShell 5.1 compatible (checked in CI), and runs as SYSTEM

## Quick start

```powershell
git clone https://github.com/ich74851-doom/rmm-automation-scripts.git
cd rmm-automation-scripts
.\scripts\Get-PendingRebootStatus.ps1
.\scripts\Invoke-DiskCleanup.ps1 -WhatIf
```

To deploy a script through your RMM, upload the single `.ps1` file, run it as SYSTEM and alert
on a non-zero exit code. [docs/rmm-platform-notes.md](docs/rmm-platform-notes.md) has
platform-specific tips.

## Usage

```powershell
# Allow up to 2 missing security updates and 45 days since the last install
.\scripts\Get-WindowsUpdateStatus.ps1 -MaxMissingSecurity 2 -MaxDaysSinceLastInstall 45

# Clean files older than 14 days and alert if C: is still below 10% free
.\scripts\Invoke-DiskCleanup.ps1 -OlderThanDays 14 -MinFreePercent 10 -LogPath C:\ProgramData\RmmScripts\Logs\cleanup.log

# Self-heal the print spooler: restart it even if running, 3 retries
.\scripts\Restart-ServiceWithLogging.ps1 -Name Spooler -Force -RetryCount 3

# Ignore PendingFileRenameOperations (often set permanently by security agents)
.\scripts\Get-PendingRebootStatus.ps1 -IgnoreFileRename
```

Example output:

```text
2026-10-24 09:00:00 [INFO] Free space before: 9.8 GB (8.2%) on C:
2026-10-24 09:00:00 [INFO] Cleaning files older than 7 day(s) in C:\Windows\Temp
2026-10-24 09:00:04 [INFO] Removed 1342 file(s), 2210.4 MB; skipped 3 locked file(s)
2026-10-24 09:00:04 [INFO] Free space after: 12.0 GB (10.0%)
2026-10-24 09:00:04 [WARN] Free space still below 15%
RESULT: ISSUE (exit 1) - Removed 2210.4 MB; free space 10% is below 15%
```

The values above are illustrative.

## Project structure

```text
rmm-automation-scripts/
├── scripts/                  # one self-contained script per task
├── docs/
│   ├── exit-codes.md         # exit-code and output contract
│   └── rmm-platform-notes.md # NinjaOne, Syncro, Datto RMM, ConnectWise deployment notes
├── tests/RmmScripts.Tests.ps1
└── .github/workflows/ci.yml  # PSScriptAnalyzer (5.1 + 7 syntax) and Pester
```

## Testing

```powershell
Invoke-Pester ./tests -Output Detailed
Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1
```

The tests dot-source each script, which loads its functions without running it, and mock
the registry, service and Windows Update calls. They run on Linux in CI. Test before you
roll out to a fleet: start with one device, then a pilot group.

## Roadmap

- [ ] `Get-BackupAgentStatus.ps1`: generic check that backup agent services are running and
  recent backup events are present
- [ ] `Get-LocalAdminAudit.ps1`: report local Administrators group membership
- [ ] Optional wrappers that write results to NinjaOne custom fields and Datto RMM UDFs
- [ ] `Invoke-WindowsUpdateInstall.ps1`: install approved updates in a maintenance window

## License

[MIT](LICENSE) © Ishant Choudhary
