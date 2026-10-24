# Exit code and output conventions

Every script in this repository follows the same contract, so one RMM monitor or
alert policy can work with all of them.

## Exit codes

| Code | Meaning | Typical RMM action |
|---|---|---|
| `0` | Healthy, or the remediation succeeded | None (success) |
| `1` | Issue detected, and the script did not or could not fix it (detection-only check) | Raise an alert or ticket |
| `2` | Remediation was attempted and failed, or an unexpected error occurred | Raise a high-priority alert |
| `3` | Prerequisite missing or the platform is not supported (for example, not Windows, not elevated, or a COM API is unavailable) | Review the script deployment |

Codes above `0` are failures for most RMM platforms, which is what you want for alerting.
If your platform treats every non-zero exit as the same failure, the code is still written
to the last output line (see below), so the reason is visible in the script result.

## Output

- Each script prints timestamped log lines in the form `2026-10-24 09:00:00 [INFO] message`
  (levels: `INFO`, `WARN`, `ERROR`).
- The last line is always a one-line summary in the form `RESULT: <status> (exit <code>) - <summary>`,
  for example `RESULT: ISSUE (exit 1) - Reboot pending: Windows Update`.
- `-LogPath` also appends the same lines to a file. The default is no file. A common choice
  is `C:\ProgramData\RmmScripts\Logs`.

## Script design rules

- **Self-contained:** no shared module, because each file is pasted into or uploaded to an
  RMM on its own. The small logging function is duplicated on purpose.
- **Safe by default:** anything that deletes or restarts supports `-WhatIf`.
- **No secrets** in parameters or output.
- **Testable:** dot-sourcing a script (`. .\script.ps1`) loads its functions without running
  it. The Pester tests use this.
