#Requires -Version 5.1
<#
.SYNOPSIS
    Detects whether Windows has a reboot pending and reports why.

.DESCRIPTION
    Checks the standard pending-reboot signals:
      - Component Based Servicing  (...\Component Based Servicing\RebootPending)
      - Windows Update             (...\WindowsUpdate\Auto Update\RebootRequired)
      - Pending file renames       (Session Manager\PendingFileRenameOperations)
      - Computer rename            (ActiveComputerName differs from ComputerName)
      - SCCM/ConfigMgr client      (CCM_ClientUtilities.DetermineIfRebootPending), if the client is installed

    This script only detects. It never reboots.

    Exit codes: 0 = no reboot pending, 1 = reboot pending, 3 = not Windows.

.PARAMETER IgnoreFileRename
    Ignore PendingFileRenameOperations. Some security and backup agents set this
    permanently, which causes noisy alerts.

.PARAMETER LogPath
    Optional log file to append to.

.EXAMPLE
    .\Get-PendingRebootStatus.ps1
.EXAMPLE
    .\Get-PendingRebootStatus.ps1 -IgnoreFileRename -LogPath C:\ProgramData\RmmScripts\Logs\reboot.log
#>
[CmdletBinding()]
param(
    [switch]$IgnoreFileRename,
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


function Get-PendingRebootSignal {
    <#
    .SYNOPSIS
        Reads the pending-reboot signals from the registry (and ConfigMgr, if present).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([switch]$IgnoreFileRename)

    $reasons = New-Object System.Collections.Generic.List[string]
    if (Test-Path -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') {
        $reasons.Add('Component Based Servicing')
    }
    if (Test-Path -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') {
        $reasons.Add('Windows Update')
    }
    if (-not $IgnoreFileRename) {
        $sm = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name 'PendingFileRenameOperations' -ErrorAction SilentlyContinue
        if ($sm -and @($sm.PendingFileRenameOperations | Where-Object { $_ }).Count -gt 0) { $reasons.Add('Pending file rename operations') }
    }
    $active = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName' -ErrorAction SilentlyContinue).ComputerName
    $target = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName' -ErrorAction SilentlyContinue).ComputerName
    if ($active -and $target -and ($active -ne $target)) { $reasons.Add('Computer rename') }

    try {
        $ccm = Invoke-CimMethod -Namespace 'root\ccm\ClientSDK' -ClassName 'CCM_ClientUtilities' -MethodName 'DetermineIfRebootPending' -ErrorAction Stop
        if ($ccm.RebootPending -or $ccm.IsHardRebootPending) { $reasons.Add('ConfigMgr client') }
    }
    catch {
        Write-Verbose 'ConfigMgr client not present; skipping.'
    }

    [pscustomobject]@{ RebootPending = ($reasons.Count -gt 0); Reasons = $reasons.ToArray() }
}

function Invoke-Main {
    [CmdletBinding()]
    param([switch]$IgnoreFileRename, [string]$LogPath)
    if ($PSVersionTable.PSEdition -eq 'Core' -and -not $IsWindows) {
        Write-RmmLog -Level ERROR -Message 'This script requires Windows.' -LogPath $LogPath
        Format-RmmResult -ExitCode 3 -Summary 'Not Windows'
        return 3
    }
    $state = Get-PendingRebootSignal -IgnoreFileRename:$IgnoreFileRename
    if ($state.RebootPending) {
        $why = $state.Reasons -join ', '
        Write-RmmLog -Level WARN -Message "Reboot pending: $why" -LogPath $LogPath
        Format-RmmResult -ExitCode 1 -Summary "Reboot pending: $why"
        return 1
    }
    Write-RmmLog -Message 'No reboot pending.' -LogPath $LogPath
    Format-RmmResult -ExitCode 0 -Summary 'No reboot pending'
    return 0
}

if ($MyInvocation.InvocationName -ne '.') {
    $out = @(Invoke-Main -IgnoreFileRename:$IgnoreFileRename -LogPath $LogPath)
    $out[0..($out.Count - 2)] | Write-Output
    exit [int]$out[-1]
}
