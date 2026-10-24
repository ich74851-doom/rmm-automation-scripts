#Requires -Version 5.1
<#
.SYNOPSIS
    Frees disk space by removing old files from temp and cache folders, with logging and -WhatIf.

.DESCRIPTION
    Deletes files older than -OlderThanDays from a fixed list of safe locations:
      - %SystemRoot%\Temp
      - C:\Users\*\AppData\Local\Temp
      - %SystemRoot%\SoftwareDistribution\Download (Windows Update download cache)
      - %SystemRoot%\Logs\CBS\*.cab (only old CBS log cabinets)
    It also removes folders that are empty afterwards. Files that are locked or in use are
    skipped and logged. Use -Path to clean your own list of folders instead.

    The Recycle Bin, Downloads, user documents, WinSxS and backup folders are never touched.

    Exit codes:
      0 = cleanup finished and free space is at or above -MinFreePercent
      1 = cleanup finished but free space is still below -MinFreePercent
      2 = unexpected error
      3 = not Windows (when using the default locations)

.PARAMETER OlderThanDays
    Only delete files last written more than this many days ago. Default: 7.

.PARAMETER Path
    Folders to clean instead of the default locations (wildcards allowed).

.PARAMETER Drive
    Drive to measure before and after. Default: the system drive.

.PARAMETER MinFreePercent
    Free-space target used for the exit code. Default: 15.

.PARAMETER LogPath
    Optional log file to append to.

.EXAMPLE
    .\Invoke-DiskCleanup.ps1 -WhatIf
    Shows what would be removed, without deleting anything.

.EXAMPLE
    .\Invoke-DiskCleanup.ps1 -OlderThanDays 14 -MinFreePercent 10 -LogPath C:\ProgramData\RmmScripts\Logs\cleanup.log
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateRange(0, 3650)][int]$OlderThanDays = 7,
    [string[]]$Path,
    [string]$Drive = $env:SystemDrive,
    [ValidateRange(1, 99)][int]$MinFreePercent = 15,
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


function Get-DefaultCleanupPath {
    <#
    .SYNOPSIS
        Returns the default folders to clean on Windows.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([string]$SystemRoot = $env:SystemRoot, [string]$SystemDrive = $env:SystemDrive)
    @(
        # String concatenation rather than Join-Path, so the paths can be built without the drive existing.
        "$SystemRoot\Temp"
        "$SystemDrive\Users\*\AppData\Local\Temp"
        "$SystemRoot\SoftwareDistribution\Download"
        "$SystemRoot\Logs\CBS\*.cab"
    )
}

function Remove-OldFile {
    <#
    .SYNOPSIS
        Removes files older than a cutoff under the given paths, then removes empty folders.
    .OUTPUTS
        One summary object: FilesRemoved, BytesRemoved, FilesSkipped.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string[]]$Path,
        [Parameter(Mandatory)][int]$OlderThanDays,
        [datetime]$Now = (Get-Date)
    )
    $cutoff = $Now.AddDays(-$OlderThanDays)
    $removed = 0; $bytes = [long]0; $skipped = 0
    foreach ($p in $Path) {
        $items = @(Get-ChildItem -Path $p -Recurse -File -Force -ErrorAction SilentlyContinue |
                Where-Object { $_.LastWriteTime -lt $cutoff })
        foreach ($f in $items) {
            if ($PSCmdlet.ShouldProcess($f.FullName, 'Remove file')) {
                try {
                    $size = $f.Length
                    Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop
                    $removed++; $bytes += $size
                }
                catch { $skipped++ }
            }
            else {
                $removed++; $bytes += $f.Length
            }
        }
        # Remove empty folders beneath the cleaned path (deepest first); never the root itself.
        foreach ($root in @(Get-Item -Path $p -Force -ErrorAction SilentlyContinue | Where-Object PSIsContainer)) {
            $dirs = @(Get-ChildItem -LiteralPath $root.FullName -Recurse -Directory -Force -ErrorAction SilentlyContinue |
                    Sort-Object { $_.FullName.Length } -Descending)
            foreach ($d in $dirs) {
                if (-not (Get-ChildItem -LiteralPath $d.FullName -Force -ErrorAction SilentlyContinue)) {
                    if ($PSCmdlet.ShouldProcess($d.FullName, 'Remove empty folder')) {
                        Remove-Item -LiteralPath $d.FullName -Force -ErrorAction SilentlyContinue
                    }
                }
            }
        }
    }
    [pscustomobject]@{ FilesRemoved = $removed; BytesRemoved = $bytes; FilesSkipped = $skipped }
}

function Get-FreeSpacePercent {
    <#
    .SYNOPSIS
        Returns the free space percentage and free GB for the drive that holds a path.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$Drive)
    $info = New-Object System.IO.DriveInfo($Drive)
    [pscustomobject]@{
        FreePercent = [math]::Round(($info.AvailableFreeSpace / [double]$info.TotalSize) * 100, 1)
        FreeGB      = [math]::Round($info.AvailableFreeSpace / 1GB, 2)
    }
}

function Invoke-Main {
    [CmdletBinding(SupportsShouldProcess)]
    param([int]$OlderThanDays, [string[]]$Path, [string]$Drive, [int]$MinFreePercent, [string]$LogPath)
    try {
        if (-not $Path) {
            if ($PSVersionTable.PSEdition -eq 'Core' -and -not $IsWindows) {
                Write-RmmLog -Level ERROR -Message 'Default locations are Windows-only; use -Path on other platforms.' -LogPath $LogPath
                Format-RmmResult -ExitCode 3 -Summary 'Not Windows'
                return 3
            }
            $Path = Get-DefaultCleanupPath
        }
        if (-not $Drive) { $Drive = [IO.Path]::GetPathRoot((Get-Location).Path) }
        $before = Get-FreeSpacePercent -Drive $Drive
        Write-RmmLog -Message "Free space before: $($before.FreeGB) GB ($($before.FreePercent)%) on $Drive" -LogPath $LogPath
        foreach ($p in $Path) { Write-RmmLog -Message "Cleaning files older than $OlderThanDays day(s) in $p" -LogPath $LogPath }

        $r = Remove-OldFile -Path $Path -OlderThanDays $OlderThanDays -WhatIf:$WhatIfPreference
        $mb = [math]::Round($r.BytesRemoved / 1MB, 1)
        $verb = if ($WhatIfPreference) { 'Would remove' } else { 'Removed' }
        Write-RmmLog -Message "$verb $($r.FilesRemoved) file(s), $mb MB; skipped $($r.FilesSkipped) locked file(s)" -LogPath $LogPath

        $after = Get-FreeSpacePercent -Drive $Drive
        Write-RmmLog -Message "Free space after: $($after.FreeGB) GB ($($after.FreePercent)%)" -LogPath $LogPath
        if ($after.FreePercent -lt $MinFreePercent) {
            Write-RmmLog -Level WARN -Message "Free space still below $MinFreePercent%" -LogPath $LogPath
            Format-RmmResult -ExitCode 1 -Summary "$verb $mb MB; free space $($after.FreePercent)% is below $MinFreePercent%"
            return 1
        }
        Format-RmmResult -ExitCode 0 -Summary "$verb $mb MB; free space $($after.FreePercent)%"
        return 0
    }
    catch {
        Write-RmmLog -Level ERROR -Message $_.Exception.Message -LogPath $LogPath
        Format-RmmResult -ExitCode 2 -Summary 'Unexpected error during cleanup'
        return 2
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    $out = @(Invoke-Main -OlderThanDays $OlderThanDays -Path $Path -Drive $Drive -MinFreePercent $MinFreePercent -LogPath $LogPath -WhatIf:$WhatIfPreference)
    $out[0..($out.Count - 2)] | Write-Output
    exit [int]$out[-1]
}
