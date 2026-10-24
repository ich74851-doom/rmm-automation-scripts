#Requires -Version 5.1
<#
.SYNOPSIS
    Reports missing Windows updates and the age of the last successful update install.

.DESCRIPTION
    Uses the Windows Update Agent COM API (Microsoft.Update.Session) to:
      - search for applicable updates that are not installed and not hidden
      - read the update history to find the most recent successful install
    It then evaluates the results against thresholds. Nothing is downloaded or installed.

    Exit codes:
      0 = compliant
      1 = non-compliant (missing security/critical updates above the threshold, or the last install is too old)
      2 = the Windows Update search failed
      3 = not Windows, or the WUA COM API is unavailable

.PARAMETER MaxMissingSecurity
    Missing security or critical updates allowed before the device counts as non-compliant. Default: 0.

.PARAMETER MaxDaysSinceLastInstall
    Days since the last successful install before the device counts as non-compliant. Default: 35.

.PARAMETER IncludeDrivers
    Include driver updates in the search. By default, only software updates are searched.

.PARAMETER LogPath
    Optional log file to append to.

.EXAMPLE
    .\Get-WindowsUpdateStatus.ps1
.EXAMPLE
    .\Get-WindowsUpdateStatus.ps1 -MaxMissingSecurity 2 -MaxDaysSinceLastInstall 45
#>
[CmdletBinding()]
param(
    [ValidateRange(0, 1000)][int]$MaxMissingSecurity = 0,
    [ValidateRange(1, 3650)][int]$MaxDaysSinceLastInstall = 35,
    [switch]$IncludeDrivers,
    [string]$LogPath
)

function Write-RmmLog {
    <#
    .SYNOPSIS
        Writes a timestamped log line to the output stream and, optionally, to a log file.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO',
        [string]$LogPath
    )
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Output $line
    if ($LogPath) {
        $dir = Split-Path -Parent $LogPath
        if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force -WhatIf:$false | Out-Null }
        Add-Content -Path $LogPath -Value $line -WhatIf:$false
    }
}

function Format-RmmResult {
    <#
    .SYNOPSIS
        Builds the final "RESULT: <status> (exit <code>) - <summary>" line.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][ValidateRange(0, 3)][int]$ExitCode, [Parameter(Mandatory)][string]$Summary)
    $status = @{ 0 = 'OK'; 1 = 'ISSUE'; 2 = 'FAILED'; 3 = 'UNSUPPORTED' }[$ExitCode]
    'RESULT: {0} (exit {1}) - {2}' -f $status, $ExitCode, $Summary
}


function ConvertTo-UpdateSummary {
    <#
    .SYNOPSIS
        Summarises update objects (from IUpdateSearcher results or test data).
    .PARAMETER Update
        Objects with Title, MsrcSeverity and Categories (objects with a Name property).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([AllowEmptyCollection()][object[]]$Update = @())

    $security = 0; $titles = @()
    foreach ($u in $Update) {
        $categoryNames = @($u.Categories | ForEach-Object { $_.Name })
        $isSecurity = ($u.MsrcSeverity -in 'Critical', 'Important') -or ($categoryNames -contains 'Security Updates') -or ($categoryNames -contains 'Critical Updates')
        if ($isSecurity) { $security++ }
        $titles += $u.Title
    }
    [pscustomobject]@{
        MissingTotal    = @($Update).Count
        MissingSecurity = $security
        Titles          = $titles
    }
}

function Get-LastSuccessfulInstall {
    <#
    .SYNOPSIS
        Returns the newest Date from update history entries with ResultCode 2 (succeeded) and Operation 1 (install).
    #>
    [CmdletBinding()]
    [OutputType([Nullable[datetime]])]
    param([AllowEmptyCollection()][object[]]$History = @())
    $ok = @($History | Where-Object { $_.ResultCode -eq 2 -and $_.Operation -eq 1 } | Sort-Object Date -Descending)
    if ($ok.Count -eq 0) { return $null }
    [datetime]$ok[0].Date
}

function Get-UpdateComplianceResult {
    <#
    .SYNOPSIS
        Decides compliance and the exit code from an update summary and the last install date.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]$Summary,
        [Nullable[datetime]]$LastInstall,
        [int]$MaxMissingSecurity = 0,
        [int]$MaxDaysSinceLastInstall = 35,
        [datetime]$Now = (Get-Date)
    )
    $problems = @()
    if ($Summary.MissingSecurity -gt $MaxMissingSecurity) {
        $problems += "$($Summary.MissingSecurity) missing security/critical update(s) (allowed: $MaxMissingSecurity)"
    }
    $days = $null
    if ($null -eq $LastInstall) {
        $problems += 'No successful update install found in history'
    }
    else {
        $days = [int][math]::Floor(($Now - $LastInstall).TotalDays)
        if ($days -gt $MaxDaysSinceLastInstall) { $problems += "Last successful install $days day(s) ago (allowed: $MaxDaysSinceLastInstall)" }
    }
    [pscustomobject]@{
        Compliant             = ($problems.Count -eq 0)
        ExitCode              = $(if ($problems.Count -eq 0) { 0 } else { 1 })
        DaysSinceLastInstall  = $days
        Problems              = $problems
    }
}

function Invoke-Main {
    [CmdletBinding()]
    param([int]$MaxMissingSecurity, [int]$MaxDaysSinceLastInstall, [switch]$IncludeDrivers, [string]$LogPath)

    if ($PSVersionTable.PSEdition -eq 'Core' -and -not $IsWindows) {
        Write-RmmLog -Level ERROR -Message 'This script requires Windows.' -LogPath $LogPath
        Format-RmmResult -ExitCode 3 -Summary 'Not Windows'
        return 3
    }
    try { $session = New-Object -ComObject 'Microsoft.Update.Session' }
    catch {
        Write-RmmLog -Level ERROR -Message "Windows Update Agent COM API unavailable: $($_.Exception.Message)" -LogPath $LogPath
        Format-RmmResult -ExitCode 3 -Summary 'WUA COM API unavailable'
        return 3
    }

    try {
        $searcher = $session.CreateUpdateSearcher()
        $criteria = 'IsInstalled=0 and IsHidden=0'
        if (-not $IncludeDrivers) { $criteria += " and Type='Software'" }
        Write-RmmLog -Message "Searching for updates ($criteria)..." -LogPath $LogPath
        $result = $searcher.Search($criteria)
        $updates = @(); foreach ($u in $result.Updates) { $updates += $u }
        $historyCount = $searcher.GetTotalHistoryCount()
        $history = @()
        if ($historyCount -gt 0) { foreach ($h in $searcher.QueryHistory(0, [math]::Min($historyCount, 200))) { $history += $h } }
    }
    catch {
        Write-RmmLog -Level ERROR -Message "Windows Update search failed: $($_.Exception.Message)" -LogPath $LogPath
        Format-RmmResult -ExitCode 2 -Summary 'Windows Update search failed'
        return 2
    }

    $summary = ConvertTo-UpdateSummary -Update $updates
    $last = Get-LastSuccessfulInstall -History $history
    $eval = Get-UpdateComplianceResult -Summary $summary -LastInstall $last -MaxMissingSecurity $MaxMissingSecurity -MaxDaysSinceLastInstall $MaxDaysSinceLastInstall

    Write-RmmLog -Message "Missing updates: $($summary.MissingTotal) (security/critical: $($summary.MissingSecurity))" -LogPath $LogPath
    foreach ($t in $summary.Titles) { Write-RmmLog -Message "  - $t" -LogPath $LogPath }
    $lastText = if ($last) { $last.ToString('yyyy-MM-dd') } else { 'never' }
    Write-RmmLog -Message "Last successful install: $lastText" -LogPath $LogPath

    if ($eval.Compliant) {
        Format-RmmResult -ExitCode 0 -Summary "Compliant: $($summary.MissingTotal) missing, last install $lastText"
    }
    else {
        foreach ($p in $eval.Problems) { Write-RmmLog -Level WARN -Message $p -LogPath $LogPath }
        Format-RmmResult -ExitCode 1 -Summary ($eval.Problems -join '; ')
    }
    return $eval.ExitCode
}

if ($MyInvocation.InvocationName -ne '.') {
    $out = @(Invoke-Main -MaxMissingSecurity $MaxMissingSecurity -MaxDaysSinceLastInstall $MaxDaysSinceLastInstall -IncludeDrivers:$IncludeDrivers -LogPath $LogPath)
    $out[0..($out.Count - 2)] | Write-Output
    exit [int]$out[-1]
}
