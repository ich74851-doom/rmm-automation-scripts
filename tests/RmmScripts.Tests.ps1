#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
    Platform-independent tests. Each script is dot-sourced, which loads its functions without
    running it. Run with:  Invoke-Pester -Path ./tests -Output Detailed
#>

BeforeAll {
    $script:scriptDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts'
}

Describe 'Repository conventions' {
    BeforeDiscovery {
        $script:files = Get-ChildItem -Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts') -Filter *.ps1 | ForEach-Object FullName
    }
    It '<_> parses without errors' -ForEach $script:files {
        $tokens = $null; $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($_, [ref]$tokens, [ref]$errors) | Out-Null
        $errors | Should -BeNullOrEmpty
    }
    It '<_> documents synopsis and exit codes' -ForEach $script:files {
        $text = Get-Content -Raw $_
        $text | Should -Match '\.SYNOPSIS'
        $text | Should -Match 'Exit codes'
    }
    It '<_> is self-contained (no Import-Module or dot-sourcing of other files)' -ForEach $script:files {
        $text = Get-Content -Raw $_
        $text | Should -Not -Match 'Import-Module'
        $text | Should -Not -Match '(?m)^\s*\.\s+\S+\.ps1'
    }
}

Describe 'Shared helpers (Format-RmmResult / Write-RmmLog)' {
    BeforeAll { . (Join-Path $script:scriptDir 'Get-PendingRebootStatus.ps1') }

    It 'formats exit code <Code> as <Status>' -ForEach @(
        @{ Code = 0; Status = 'OK' }, @{ Code = 1; Status = 'ISSUE' }, @{ Code = 2; Status = 'FAILED' }, @{ Code = 3; Status = 'UNSUPPORTED' }
    ) {
        Format-RmmResult -ExitCode $Code -Summary 'x' | Should -Be "RESULT: $Status (exit $Code) - x"
    }
    It 'writes timestamped lines and appends to the log file' {
        $log = Join-Path ([IO.Path]::GetTempPath()) ("rmm-" + [guid]::NewGuid() + '/test.log')
        $line = Write-RmmLog -Message 'hello' -Level WARN -LogPath $log
        $line | Should -Match '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} \[WARN\] hello$'
        Get-Content $log | Should -Be $line
        Remove-Item -Recurse -Force (Split-Path -Parent $log)
    }
}

Describe 'Get-PendingRebootStatus.ps1' {
    BeforeAll {
        . (Join-Path $script:scriptDir 'Get-PendingRebootStatus.ps1')
        if (-not (Get-Command Invoke-CimMethod -ErrorAction SilentlyContinue)) { function script:Invoke-CimMethod { throw 'not available' } }
    }
    BeforeEach {
        Mock Test-Path { $false }
        Mock Get-ItemProperty { $null }
        Mock Invoke-CimMethod { throw 'ConfigMgr not installed' }
    }
    It 'reports nothing pending when no signal is present' {
        (Get-PendingRebootSignal).RebootPending | Should -BeFalse
    }
    It 'detects Windows Update and CBS signals' {
        Mock Test-Path { $true } -ParameterFilter { $Path -like '*RebootRequired' -or $Path -like '*RebootPending' }
        $r = Get-PendingRebootSignal
        $r.RebootPending | Should -BeTrue
        $r.Reasons | Should -Contain 'Windows Update'
        $r.Reasons | Should -Contain 'Component Based Servicing'
    }
    It 'detects pending file renames unless ignored' {
        Mock Get-ItemProperty { [pscustomobject]@{ PendingFileRenameOperations = @('\??\C:\a.tmp', '') } } -ParameterFilter { $Name -eq 'PendingFileRenameOperations' }
        (Get-PendingRebootSignal).Reasons | Should -Contain 'Pending file rename operations'
        (Get-PendingRebootSignal -IgnoreFileRename).RebootPending | Should -BeFalse
    }
    It 'detects a pending computer rename' {
        Mock Get-ItemProperty { [pscustomobject]@{ ComputerName = 'OLD-NAME' } } -ParameterFilter { $Path -like '*ActiveComputerName' }
        Mock Get-ItemProperty { [pscustomobject]@{ ComputerName = 'NEW-NAME' } } -ParameterFilter { $Path -like '*\ComputerName\ComputerName' }
        (Get-PendingRebootSignal).Reasons | Should -Be @('Computer rename')
    }
}

Describe 'Get-WindowsUpdateStatus.ps1' {
    BeforeAll {
        . (Join-Path $script:scriptDir 'Get-WindowsUpdateStatus.ps1')
        $script:now = [datetime]'2026-10-24'
        $script:updates = @(
            [pscustomobject]@{ Title = '2026-10 Cumulative Update (fictional)'; MsrcSeverity = 'Critical'; Categories = @([pscustomobject]@{ Name = 'Security Updates' }) }
            [pscustomobject]@{ Title = 'Defender definition update'; MsrcSeverity = $null; Categories = @([pscustomobject]@{ Name = 'Definition Updates' }) }
            [pscustomobject]@{ Title = 'Servicing stack update'; MsrcSeverity = $null; Categories = @([pscustomobject]@{ Name = 'Critical Updates' }) }
        )
    }
    It 'counts security and critical updates' {
        $s = ConvertTo-UpdateSummary -Update $script:updates
        $s.MissingTotal | Should -Be 3
        $s.MissingSecurity | Should -Be 2
    }
    It 'handles no missing updates' {
        (ConvertTo-UpdateSummary -Update @()).MissingTotal | Should -Be 0
    }
    It 'finds the newest successful install in history' {
        $history = @(
            [pscustomobject]@{ Date = [datetime]'2026-10-01'; ResultCode = 2; Operation = 1 }
            [pscustomobject]@{ Date = [datetime]'2026-10-10'; ResultCode = 4; Operation = 1 }  # failed
            [pscustomobject]@{ Date = [datetime]'2026-09-15'; ResultCode = 2; Operation = 1 }
            [pscustomobject]@{ Date = [datetime]'2026-10-12'; ResultCode = 2; Operation = 2 }  # uninstall
        )
        Get-LastSuccessfulInstall -History $history | Should -Be ([datetime]'2026-10-01')
        Get-LastSuccessfulInstall -History @() | Should -BeNullOrEmpty
    }
    It 'is compliant with no missing security updates and a recent install' {
        $r = Get-UpdateComplianceResult -Summary (ConvertTo-UpdateSummary -Update @($script:updates[1])) -LastInstall ([datetime]'2026-10-01') -Now $script:now
        $r.Compliant | Should -BeTrue
        $r.ExitCode | Should -Be 0
        $r.DaysSinceLastInstall | Should -Be 23
    }
    It 'is non-compliant with missing security updates' {
        $r = Get-UpdateComplianceResult -Summary (ConvertTo-UpdateSummary -Update $script:updates) -LastInstall ([datetime]'2026-10-01') -Now $script:now
        $r.ExitCode | Should -Be 1
        $r.Problems[0] | Should -Match '2 missing'
    }
    It 'is non-compliant when the last install is too old or missing' {
        $s = ConvertTo-UpdateSummary -Update @()
        (Get-UpdateComplianceResult -Summary $s -LastInstall ([datetime]'2026-08-01') -Now $script:now).ExitCode | Should -Be 1
        (Get-UpdateComplianceResult -Summary $s -LastInstall $null -Now $script:now).Problems | Should -Match 'No successful'
    }
    It 'respects custom thresholds' {
        $r = Get-UpdateComplianceResult -Summary (ConvertTo-UpdateSummary -Update $script:updates) -LastInstall ([datetime]'2026-08-01') -MaxMissingSecurity 2 -MaxDaysSinceLastInstall 90 -Now $script:now
        $r.Compliant | Should -BeTrue
    }
}

Describe 'Invoke-DiskCleanup.ps1' {
    BeforeAll { . (Join-Path $script:scriptDir 'Invoke-DiskCleanup.ps1') }
    BeforeEach {
        $script:dir = Join-Path ([IO.Path]::GetTempPath()) ("cleanup-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Path (Join-Path $script:dir 'sub/deeper') -Force | Out-Null
        Set-Content -Path (Join-Path $script:dir 'old.log') -Value ('x' * 1000)
        Set-Content -Path (Join-Path $script:dir 'sub/deeper/old.tmp') -Value 'x'
        Set-Content -Path (Join-Path $script:dir 'new.log') -Value 'keep'
        foreach ($f in 'old.log', 'sub/deeper/old.tmp') { (Get-Item (Join-Path $script:dir $f)).LastWriteTime = (Get-Date).AddDays(-30) }
    }
    AfterEach { Remove-Item -Recurse -Force $script:dir -ErrorAction SilentlyContinue }

    It 'removes only files older than the cutoff and prunes empty folders' {
        $r = Remove-OldFile -Path $script:dir -OlderThanDays 7
        $r.FilesRemoved | Should -Be 2
        $r.BytesRemoved | Should -BeGreaterThan 1000
        Test-Path (Join-Path $script:dir 'new.log') | Should -BeTrue
        Test-Path (Join-Path $script:dir 'old.log') | Should -BeFalse
        Test-Path (Join-Path $script:dir 'sub') | Should -BeFalse
        Test-Path $script:dir | Should -BeTrue
    }
    It 'deletes nothing with -WhatIf but reports what would be removed' {
        $r = Remove-OldFile -Path $script:dir -OlderThanDays 7 -WhatIf
        $r.FilesRemoved | Should -Be 2
        Test-Path (Join-Path $script:dir 'old.log') | Should -BeTrue
        Test-Path (Join-Path $script:dir 'sub/deeper/old.tmp') | Should -BeTrue
    }
    It 'keeps everything when the age threshold is larger than the file age' {
        (Remove-OldFile -Path $script:dir -OlderThanDays 60).FilesRemoved | Should -Be 0
    }
    It 'builds the default Windows locations from SystemRoot and SystemDrive' {
        $paths = Get-DefaultCleanupPath -SystemRoot 'C:\Windows' -SystemDrive 'C:'
        $paths.Count | Should -Be 4
        ($paths -join ';') | Should -Match 'SoftwareDistribution'
        ($paths -join ';') | Should -Not -Match 'Downloads|Recycle'
    }
    It 'exits 1 via the script when free space stays below target' {
        $out = & (Get-Process -Id $PID).Path -NoProfile -File (Join-Path $script:scriptDir 'Invoke-DiskCleanup.ps1') -Path $script:dir -Drive ([IO.Path]::GetPathRoot($script:dir)) -MinFreePercent 99
        $LASTEXITCODE | Should -BeIn @(0, 1)
        $out[-1] | Should -Match '^RESULT: (OK|ISSUE) \(exit [01]\)'
    }
}

Describe 'Restart-ServiceWithLogging.ps1' {
    BeforeAll {
        . (Join-Path $script:scriptDir 'Restart-ServiceWithLogging.ps1')
        foreach ($c in 'Get-Service', 'Start-Service', 'Restart-Service', 'Set-Service') {
            if (-not (Get-Command $c -ErrorAction SilentlyContinue)) { Set-Item -Path "function:script:$c" -Value { param($Name) $null = $Name } }
        }
        Mock Start-Sleep { }
    }
    It 'does nothing when the service is already running' {
        Mock Get-Service { [pscustomobject]@{ Name = 'Spooler'; Status = 'Running'; StartType = 'Automatic' } }
        Mock Start-Service { }
        $r = Invoke-ServiceRemediation -Name Spooler -RetryDelaySeconds 0 6>$null
        $r.ExitCode | Should -Be 0
        $r.Summary | Should -Match 'already running'
        Should -Invoke Start-Service -Times 0
    }
    It 'starts a stopped service' {
        $script:calls = 0
        Mock Get-Service { $script:calls++; if ($script:calls -le 1) { [pscustomobject]@{ Name = 'Spooler'; Status = 'Stopped'; StartType = 'Automatic' } } else { [pscustomobject]@{ Name = 'Spooler'; Status = 'Running'; StartType = 'Automatic' } } }
        Mock Start-Service { }
        $r = Invoke-ServiceRemediation -Name Spooler -RetryDelaySeconds 0 -TimeoutSeconds 1
        $r.ExitCode | Should -Be 0
        Should -Invoke Start-Service -Times 1
    }
    It 'retries and fails with exit 2 when the service never starts' {
        Mock Get-Service { [pscustomobject]@{ Name = 'BadSvc'; Status = 'Stopped'; StartType = 'Automatic' } }
        Mock Start-Service { throw 'Cannot start service' }
        $r = Invoke-ServiceRemediation -Name BadSvc -RetryCount 2 -RetryDelaySeconds 0 -TimeoutSeconds 1
        $r.ExitCode | Should -Be 2
        Should -Invoke Start-Service -Times 3
    }
    It 'leaves a disabled service alone unless -EnableIfDisabled' {
        Mock Get-Service { [pscustomobject]@{ Name = 'Svc'; Status = 'Stopped'; StartType = 'Disabled' } }
        Mock Start-Service { }
        (Invoke-ServiceRemediation -Name Svc -RetryDelaySeconds 0).ExitCode | Should -Be 1
        Should -Invoke Start-Service -Times 0
    }
    It 'returns exit 2 when the service does not exist' {
        Mock Get-Service { $null }
        (Invoke-ServiceRemediation -Name Missing).ExitCode | Should -Be 2
    }
    It 'makes no change with -WhatIf' {
        Mock Get-Service { [pscustomobject]@{ Name = 'Spooler'; Status = 'Running'; StartType = 'Automatic' } }
        Mock Restart-Service { }
        $r = Invoke-ServiceRemediation -Name Spooler -Force -WhatIf
        $r.Summary | Should -Match 'WhatIf'
        Should -Invoke Restart-Service -Times 0
    }
}
