# Builds windows\build\WinterDesk.exe with MSVC (located via vswhere), static CRT, no third-party libraries.
#   powershell -ExecutionPolicy Bypass -File windows\build.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$src = Join-Path $root 'src'
$out = Join-Path $root 'build'

$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path $vswhere)) { throw "vswhere.exe not found at $vswhere (install Visual Studio Build Tools with the C++ workload)" }
$vs = & $vswhere -products * -latest -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $vs) { throw 'No Visual Studio instance with the x64 C++ tools (Microsoft.VisualStudio.Component.VC.Tools.x86.x64) was found' }
$vcvars = Join-Path $vs 'VC\Auxiliary\Build\vcvars64.bat'
if (-not (Test-Path $vcvars)) { throw "vcvars64.bat not found under $vs" }
Write-Host "Using MSVC from $vs"

# Import the vcvars64 environment into this PowerShell session.
$envDump = & cmd.exe /s /c "`"$vcvars`" >nul 2>&1 && set"
if ($LASTEXITCODE -ne 0) { throw "vcvars64.bat failed ($LASTEXITCODE)" }
foreach ($line in $envDump) {
    $i = $line.IndexOf('=')
    if ($i -gt 0) { [Environment]::SetEnvironmentVariable($line.Substring(0, $i), $line.Substring($i + 1), 'Process') }
}

New-Item -ItemType Directory -Force -Path $out | Out-Null
$sources = Get-ChildItem -Path $src -Filter *.cpp | ForEach-Object { $_.FullName }
$exe = Join-Path $out 'WinterDesk.exe'
$clArgs = @('/nologo', '/O2', '/EHsc', '/std:c++17', '/W4', '/MT', '/DUNICODE', '/D_UNICODE', '/utf-8',
            "/Fo$out\\", "/Fe$exe") + $sources + @('/link', '/SUBSYSTEM:WINDOWS', '/OPT:REF', '/OPT:ICF',
            'd3d11.lib', 'dxgi.lib', 'dcomp.lib', 'd2d1.lib', 'dwrite.lib', 'user32.lib', 'gdi32.lib', 'shell32.lib',
            'shcore.lib', 'dwmapi.lib', 'wtsapi32.lib', 'advapi32.lib', 'ole32.lib')
& cl.exe @clArgs
if ($LASTEXITCODE -ne 0) { throw "cl.exe failed ($LASTEXITCODE)" }
Write-Host "Built $exe"
