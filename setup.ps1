# WinterDesk setup for Windows 10/11 (no admin needed). Installs or updates the latest release.
#
#   Install / update:  irm https://github.com/sitdownSeungpyo/mac_snow/releases/latest/download/setup.ps1 | iex
#   Uninstall:         & ([scriptblock]::Create((irm https://github.com/sitdownSeungpyo/mac_snow/releases/latest/download/setup.ps1))) -Uninstall
#   As a file:         powershell -ExecutionPolicy Bypass -File setup.ps1 [-Uninstall]
#
# What it does: downloads WinterDesk-windows-x64.zip from the latest GitHub release, checks its SHA256
# against SHA256SUMS.txt, quits a running WinterDesk, installs to %LOCALAPPDATA%\Programs\WinterDesk,
# adds a Start Menu shortcut, turns on Launch at Login (HKCU ...\Run, the same value the app's own
# menu writes) and starts the app. Re-running it updates in place. Settings in %APPDATA%\WinterDesk are kept.
#
# Testing parameters: -SourceZip <zip> (SHA256SUMS.txt must sit next to it), -InstallDir <dir>,
# -NoStart, -NoLogin (do not touch the Run key), -NoShortcut.
#
# This file is ASCII only on purpose: Windows PowerShell 5.1 decodes `irm` downloads served as
# application/octet-stream as Latin-1, so Korean text is stored as \u escapes and decoded at run time.
param(
    [switch]$Uninstall,
    [string]$SourceZip,
    [string]$InstallDir,
    [switch]$NoStart,
    [switch]$NoLogin,
    [switch]$NoShortcut
)

function Invoke-WinterDeskSetup {
    param([bool]$Uninstall, [string]$SourceZip, [string]$InstallDir, [bool]$NoStart, [bool]$NoLogin, [bool]$NoShortcut)
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'   # Invoke-WebRequest is very slow with the progress bar on 5.1

    $repo = 'sitdownSeungpyo/mac_snow'
    $zipName = 'WinterDesk-windows-x64.zip'
    $baseUrl = "https://github.com/$repo/releases/latest/download"
    $runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    $runName = 'WinterDesk'
    if (-not $InstallDir) { $InstallDir = Join-Path $env:LOCALAPPDATA 'Programs\WinterDesk' }
    $InstallDir = [IO.Path]::GetFullPath($InstallDir).TrimEnd('\')
    $exe = Join-Path $InstallDir 'WinterDesk.exe'
    $shortcut = Join-Path ([Environment]::GetFolderPath('Programs')) 'WinterDesk.lnk'

    function Say([string]$en, [string]$ko, [string]$color = 'Gray') {
        Write-Host ("  {0}  /  {1}" -f $en, [regex]::Unescape($ko)) -ForegroundColor $color
    }

    # Quit running WinterDesk instances. -OnlyInstalled: only the copy in $InstallDir.
    # Graceful first: the control window (class WinterDeskControl) handles WM_HOTKEY id 1 (the
    # Ctrl+Alt+Shift+Q emergency-quit hotkey) by posting WM_QUIT, which saves state and exits
    # cleanly. WM_CLOSE is not used: it would destroy the window without ending the message loop.
    function Stop-WinterDesk([bool]$OnlyInstalled) {
        $procs = @(Get-Process -Name WinterDesk -ErrorAction SilentlyContinue | Where-Object {
            -not $OnlyInstalled -or ($_.Path -and $_.Path.StartsWith($InstallDir + '\', [StringComparison]::OrdinalIgnoreCase))
        })
        if ($procs.Count -eq 0) { return }
        Say 'Quitting the running WinterDesk' '\uC2E4\uD589 \uC911\uC778 WinterDesk\uB97C \uC885\uB8CC\uD569\uB2C8\uB2E4'
        try {
            if (-not ('WinterDeskSetup.Native' -as [type])) {
                Add-Type -Namespace WinterDeskSetup -Name Native -MemberDefinition @'
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string cls, string title);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
[DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hwnd, uint msg, IntPtr w, IntPtr l);
'@
            }
            $ids = $procs | ForEach-Object { [uint32]$_.Id }
            $h = [IntPtr]::Zero
            while (($h = [WinterDeskSetup.Native]::FindWindowEx([IntPtr]::Zero, $h, 'WinterDeskControl', $null)) -ne [IntPtr]::Zero) {
                $winPid = [uint32]0
                [void][WinterDeskSetup.Native]::GetWindowThreadProcessId($h, [ref]$winPid)
                if ($ids -contains $winPid) { [void][WinterDeskSetup.Native]::PostMessage($h, 0x0312, [IntPtr]1, [IntPtr]::Zero) }
            }
        } catch {
            Write-Host "  (graceful quit unavailable: $($_.Exception.Message))" -ForegroundColor DarkGray
        }
        foreach ($p in $procs) {
            if (-not $p.WaitForExit(8000)) {
                Say 'WinterDesk did not quit in time; stopping it' 'WinterDesk\uAC00 \uC751\uB2F5\uD558\uC9C0 \uC54A\uC544 \uAC15\uC81C \uC885\uB8CC\uD569\uB2C8\uB2E4' 'Yellow'
                Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
                [void]$p.WaitForExit(5000)
            }
        }
    }

    function Test-RunValueIsOurs {
        $v = (Get-ItemProperty -Path $runKey -Name $runName -ErrorAction SilentlyContinue).$runName
        return ($v -and $v.Trim('"') -ieq $exe)
    }

    Write-Host ''
    Write-Host '  WinterDesk setup' -ForegroundColor Cyan
    Write-Host "  $InstallDir" -ForegroundColor DarkGray
    Write-Host ''

    if ($Uninstall) {
        Stop-WinterDesk -OnlyInstalled $true   # only the copy whose files are about to be deleted
        if (-not $NoLogin) {
            if (Test-RunValueIsOurs) {
                Remove-ItemProperty -Path $runKey -Name $runName
                Say 'Launch at Login removed' '\uB85C\uADF8\uC778 \uC2DC \uC2E4\uD589 \uD574\uC81C'
            }
        }
        if (-not $NoShortcut -and (Test-Path -LiteralPath $shortcut)) {
            Remove-Item -LiteralPath $shortcut -Force
            Say 'Start Menu shortcut removed' '\uC2DC\uC791 \uBA54\uB274 \uBC14\uB85C\uAC00\uAE30 \uC0AD\uC81C'
        }
        if (Test-Path -LiteralPath $InstallDir) {
            Remove-Item -LiteralPath $InstallDir -Recurse -Force
            Say 'App files removed' '\uC571 \uD30C\uC77C \uC0AD\uC81C'
        }
        Say 'WinterDesk uninstalled. Settings kept in %APPDATA%\WinterDesk' 'WinterDesk \uC81C\uAC70 \uC644\uB8CC. \uC124\uC815\uC740 %APPDATA%\\WinterDesk \uC5D0 \uB0A8\uC544 \uC788\uC2B5\uB2C8\uB2E4' 'Green'
        return
    }

    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('WinterDesk-setup-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp | Out-Null
    try {
        # 1. Get the zip and SHA256SUMS.txt
        if ($SourceZip) {
            $zip = [IO.Path]::GetFullPath($SourceZip)
            $sums = Join-Path (Split-Path -Parent $zip) 'SHA256SUMS.txt'
            if (-not (Test-Path -LiteralPath $zip)) { throw "Source zip not found: $zip" }
            if (-not (Test-Path -LiteralPath $sums)) { throw "SHA256SUMS.txt not found next to $zip" }
            $zipKey = Split-Path -Leaf $zip
        } else {
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
            $zip = Join-Path $tmp $zipName
            $sums = Join-Path $tmp 'SHA256SUMS.txt'
            $zipKey = $zipName
            Say 'Downloading the latest release' '\uCD5C\uC2E0 \uBC84\uC804\uC744 \uB0B4\uB824\uBC1B\uB294 \uC911'
            try {
                Invoke-WebRequest -UseBasicParsing -Uri "$baseUrl/$zipName" -OutFile $zip
                Invoke-WebRequest -UseBasicParsing -Uri "$baseUrl/SHA256SUMS.txt" -OutFile $sums
            } catch {
                throw "Download failed ($baseUrl): $($_.Exception.Message). Check the internet connection or proxy and try again."
            }
        }

        # 2. Verify SHA256
        $expected = $null
        foreach ($line in Get-Content -LiteralPath $sums) {
            if ($line -match '^\s*([0-9a-fA-F]{64})\s+\*?(.+?)\s*$' -and $Matches[2] -eq $zipKey) { $expected = $Matches[1]; break }
        }
        if (-not $expected) { throw "SHA256SUMS.txt has no entry for $zipKey" }
        $actual = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash
        if ($actual -ine $expected) { throw "SHA256 mismatch for ${zipKey}: expected $expected, got $actual. The download may be corrupted; try again." }
        Say 'SHA256 verified' 'SHA256 \uD655\uC778 \uC644\uB8CC'

        # 3. Extract to a temp folder first so a bad archive never half-replaces the install
        $stage = Join-Path $tmp 'stage'
        Expand-Archive -LiteralPath $zip -DestinationPath $stage -Force
        if (-not (Test-Path -LiteralPath (Join-Path $stage 'WinterDesk.exe'))) { throw "WinterDesk.exe not found in $zipKey" }

        # 4. Quit the running app (any copy when we will start the new one: it is single-instance)
        Stop-WinterDesk -OnlyInstalled $NoStart

        # 5. Install
        New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
        try {
            Copy-Item -Path (Join-Path $stage '*') -Destination $InstallDir -Recurse -Force
        } catch {
            throw "Could not write to $InstallDir ($($_.Exception.Message)). Quit WinterDesk (Ctrl+Alt+Shift+Q) and run setup again."
        }
        Get-ChildItem -LiteralPath $InstallDir -Recurse -File | Unblock-File
        Say 'Installed' '\uC124\uCE58 \uC644\uB8CC' 'Green'

        # 6. Start Menu shortcut
        if (-not $NoShortcut) {
            $shell = New-Object -ComObject WScript.Shell
            $lnk = $shell.CreateShortcut($shortcut)
            $lnk.TargetPath = $exe
            $lnk.WorkingDirectory = $InstallDir
            $lnk.Description = 'WinterDesk'
            $lnk.Save()
            Say 'Start Menu shortcut created' '\uC2DC\uC791 \uBA54\uB274 \uBC14\uB85C\uAC00\uAE30 \uC0DD\uC131'
        }

        # 7. Launch at Login: exactly what the app writes (util.cpp SetLaunchAtLogin): REG_SZ "<exe>" with quotes
        if (-not $NoLogin) {
            if (-not (Test-Path $runKey)) { New-Item -Path $runKey -Force | Out-Null }
            New-ItemProperty -Path $runKey -Name $runName -PropertyType String -Value ('"' + $exe + '"') -Force | Out-Null
            Say 'Launch at Login enabled' '\uB85C\uADF8\uC778 \uC2DC \uC790\uB3D9 \uC2E4\uD589 \uCF1C\uC9D0'
        }

        # 8. Start
        if (-not $NoStart) {
            Start-Process -FilePath $exe -WorkingDirectory $InstallDir
            Say 'WinterDesk started: look for the snowflake in the notification area' 'WinterDesk \uC2E4\uD589\uB428: \uC54C\uB9BC \uC601\uC5ED(\uD2B8\uB808\uC774)\uC758 \uB208\uC1A1\uC774 \uC544\uC774\uCF58\uC744 \uD074\uB9AD\uD558\uC138\uC694' 'Green'
            Say 'Emergency quit: Ctrl+Alt+Shift+Q' '\uBE44\uC0C1 \uC885\uB8CC: Ctrl+Alt+Shift+Q'
        }
        Write-Host ''
        Say 'Done' '\uC644\uB8CC' 'Green'
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

try {
    Invoke-WinterDeskSetup -Uninstall ([bool]$Uninstall) -SourceZip $SourceZip -InstallDir $InstallDir `
        -NoStart ([bool]$NoStart) -NoLogin ([bool]$NoLogin) -NoShortcut ([bool]$NoShortcut)
} catch {
    Write-Host ''
    Write-Host "  WinterDesk setup failed: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host ('  ' + [regex]::Unescape('\uC124\uCE58\uC5D0 \uC2E4\uD328\uD588\uC2B5\uB2C8\uB2E4. \uC704 \uBA54\uC2DC\uC9C0\uB97C \uD655\uC778\uD55C \uB4A4 \uB2E4\uC2DC \uC2E4\uD589\uD574 \uC8FC\uC138\uC694.')) -ForegroundColor Red
    # exit only when run as a file; under `irm | iex` it would close the user's PowerShell window
    if ($PSCommandPath) { exit 1 }
}
