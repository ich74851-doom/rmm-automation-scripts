#Requires -Version 5.1
<#
.SYNOPSIS
    Makes sure a Windows service is running: starts or restarts it with retries and logs every step.

.DESCRIPTION
    Typical use is self-healing for agents and critical services, for example a backup agent,
    the print spooler, or an RMM or monitoring agent.

      - If the service is running and -Force is not set, nothing is done (exit 0).
      - If the service is stopped, it is started. With -Force, a running service is restarted.
      - Each attempt waits up to -TimeoutSeconds for the Running state. Failed attempts are
        retried up to -RetryCount times, with -RetryDelaySeconds between them.
      - Disabled services are reported and not changed, unless -EnableIfDisabled is set
        (which sets the start type to Automatic).

    Exit codes:
      0 = running (already running, or started/restarted successfully)
      1 = service is disabled and was left unchanged
      2 = start or restart failed after all retries, or the service was not found
      3 = not Windows

.PARAMETER Name
    Service name (not display name), for example 'Spooler'.

.PARAMETER Force
    Restart the service even if it is already running.

.PARAMETER RetryCount
    Number of extra attempts after the first one. Default: 2.

.PARAMETER RetryDelaySeconds
    Delay between attempts. Default: 10.

.PARAMETER TimeoutSeconds
    How long to wait for the Running state on each attempt. Default: 60.

.PARAMETER EnableIfDisabled
    Set a disabled service to Automatic before starting it.

.PARAMETER LogPath
    Optional log file to append to.

.EXAMPLE
    .\Restart-ServiceWithLogging.ps1 -Name Spooler -Force -WhatIf
.EXAMPLE
    .\Restart-ServiceWithLogging.ps1 -Name W32Time -RetryCount 3 -LogPath C:\ProgramData\RmmScripts\Logs\services.log
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$Name,
    [switch]$Force,
    [ValidateRange(0, 10)][int]$RetryCount = 2,
    [ValidateRange(0, 600)][int]$RetryDelaySeconds = 10,
    [ValidateRange(1, 600)][int]$TimeoutSeconds = 60,
    [switch]$EnableIfDisabled,
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


function Wait-ServiceRunning {
    <#
    .SYNOPSIS
        Polls a service until it is Running or the timeout expires. Returns $true when it is running.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Name, [int]$TimeoutSeconds = 60, [int]$PollSeconds = 2)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
        if ($svc -and [string]$svc.Status -eq 'Running') { return $true }
        Start-Sleep -Seconds $PollSeconds
    } while ((Get-Date) -lt $deadline)
    return $false
}

function Invoke-ServiceRemediation {
    <#
    .SYNOPSIS
        Starts or restarts a service with retries. Returns an object with ExitCode and Summary.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Name,
        [switch]$Force,
        [int]$RetryCount = 2,
        [int]$RetryDelaySeconds = 10,
        [int]$TimeoutSeconds = 60,
        [switch]$EnableIfDisabled,
        [string]$LogPath
    )
    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $svc) {
        Write-RmmLog -Level ERROR -Message "Service '$Name' not found." -LogPath $LogPath
        return [pscustomobject]@{ ExitCode = 2; Summary = "Service '$Name' not found" }
    }
    Write-RmmLog -Message "Service '$Name' status: $($svc.Status), start type: $($svc.StartType)" -LogPath $LogPath

    if ([string]$svc.StartType -eq 'Disabled') {
        if (-not $EnableIfDisabled) {
            Write-RmmLog -Level WARN -Message "Service '$Name' is disabled; leaving it unchanged (use -EnableIfDisabled)." -LogPath $LogPath
            return [pscustomobject]@{ ExitCode = 1; Summary = "Service '$Name' is disabled" }
        }
        if ($PSCmdlet.ShouldProcess($Name, 'Set start type to Automatic')) {
            Set-Service -Name $Name -StartupType Automatic -ErrorAction Stop
            Write-RmmLog -Message "Set '$Name' start type to Automatic." -LogPath $LogPath
        }
    }

    $running = ([string]$svc.Status -eq 'Running')
    if ($running -and -not $Force) {
        return [pscustomobject]@{ ExitCode = 0; Summary = "Service '$Name' already running; no action" }
    }
    $action = if ($running) { 'Restart' } else { 'Start' }
    if (-not $PSCmdlet.ShouldProcess($Name, "$action service")) {
        return [pscustomobject]@{ ExitCode = 0; Summary = "WhatIf: would $($action.ToLower()) '$Name'" }
    }

    for ($attempt = 1; $attempt -le ($RetryCount + 1); $attempt++) {
        try {
            Write-RmmLog -Message "$action attempt $attempt of $($RetryCount + 1)..." -LogPath $LogPath
            if ($action -eq 'Restart') { Restart-Service -Name $Name -Force -ErrorAction Stop }
            else { Start-Service -Name $Name -ErrorAction Stop }
            if (Wait-ServiceRunning -Name $Name -TimeoutSeconds $TimeoutSeconds) {
                Write-RmmLog -Message "Service '$Name' is running." -LogPath $LogPath
                return [pscustomobject]@{ ExitCode = 0; Summary = "Service '$Name' $($action.ToLower())ed on attempt $attempt" }
            }
            Write-RmmLog -Level WARN -Message "Service '$Name' did not reach Running within $TimeoutSeconds s." -LogPath $LogPath
        }
        catch {
            Write-RmmLog -Level WARN -Message "Attempt $attempt failed: $($_.Exception.Message)" -LogPath $LogPath
        }
        $action = 'Start'
        if ($attempt -le $RetryCount -and $RetryDelaySeconds -gt 0) { Start-Sleep -Seconds $RetryDelaySeconds }
    }
    Write-RmmLog -Level ERROR -Message "Service '$Name' could not be started after $($RetryCount + 1) attempt(s)." -LogPath $LogPath
    [pscustomobject]@{ ExitCode = 2; Summary = "Service '$Name' failed to start after $($RetryCount + 1) attempt(s)" }
}

function Invoke-Main {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$Name, [switch]$Force, [int]$RetryCount, [int]$RetryDelaySeconds, [int]$TimeoutSeconds, [switch]$EnableIfDisabled, [string]$LogPath)
    if ($PSVersionTable.PSEdition -eq 'Core' -and -not $IsWindows) {
        Write-RmmLog -Level ERROR -Message 'This script requires Windows.' -LogPath $LogPath
        Format-RmmResult -ExitCode 3 -Summary 'Not Windows'
        return 3
    }
    if (-not $Name) {
        Write-RmmLog -Level ERROR -Message '-Name is required.' -LogPath $LogPath
        Format-RmmResult -ExitCode 2 -Summary 'No service name given'
        return 2
    }
    $r = Invoke-ServiceRemediation -Name $Name -Force:$Force -RetryCount $RetryCount -RetryDelaySeconds $RetryDelaySeconds -TimeoutSeconds $TimeoutSeconds -EnableIfDisabled:$EnableIfDisabled -LogPath $LogPath -WhatIf:$WhatIfPreference
    Format-RmmResult -ExitCode $r.ExitCode -Summary $r.Summary
    return $r.ExitCode
}

if ($MyInvocation.InvocationName -ne '.') {
    $out = @(Invoke-Main -Name $Name -Force:$Force -RetryCount $RetryCount -RetryDelaySeconds $RetryDelaySeconds -TimeoutSeconds $TimeoutSeconds -EnableIfDisabled:$EnableIfDisabled -LogPath $LogPath -WhatIf:$WhatIfPreference)
    $out[0..($out.Count - 2)] | Write-Output
    exit [int]$out[-1]
}
