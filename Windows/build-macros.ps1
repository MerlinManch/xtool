[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (-not $IsWindows) { throw 'Use PowerShell 7 on native Windows.' }
$source = Join-Path $PSScriptRoot 'Dependencies/OpenAppleMacros'
$revision = '4078c0e615d288134fb2453f02616135b2b94d1b'
$dist = Join-Path $PSScriptRoot 'dist/bin/windows-macros'
function Invoke-Checked([string]$Program, [string[]]$Arguments) {
    & $Program @Arguments | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "$Program failed with exit code $LASTEXITCODE" }
}
if (-not (Test-Path $source)) {
    Invoke-Checked git @('clone', '--filter=blob:none', '--no-checkout', '--depth=1',
        'https://github.com/xtool-org/OpenAppleMacros.git', $source)
    Invoke-Checked git @('-C', $source, 'fetch', '--depth=1', 'origin', $revision)
    Invoke-Checked git @('-C', $source, 'checkout', '--detach', $revision)
}
$actual = & git -C $source rev-parse HEAD
if ($LASTEXITCODE -ne 0 -or $actual -ne $revision) { throw "Unexpected source revision at $source" }
$dirty = & git -C $source status --porcelain --untracked-files=no
if ($LASTEXITCODE -ne 0 -or $dirty) { throw "Source modifications found at $source" }
Invoke-Checked swift @('build', '--package-path', $source, '-c', 'release', '--product', 'OpenAppleMacrosServer')
$bin = & swift build --package-path $source -c release --show-bin-path
if ($LASTEXITCODE -ne 0) { throw 'Could not locate macro server build output' }
New-Item -ItemType Directory -Force $dist | Out-Null
Copy-Item (Join-Path $bin 'OpenAppleMacrosServer.exe') $dist -Force
Get-ChildItem $bin -Filter '*.dll' | Copy-Item -Destination $dist -Force
$info = [System.Diagnostics.ProcessStartInfo]::new((Join-Path $dist 'OpenAppleMacrosServer.exe'))
$info.UseShellExecute = $false
$info.RedirectStandardInput = $true
$process = [System.Diagnostics.Process]::Start($info)
try {
    $process.StandardInput.Close()
    if (-not $process.WaitForExit(30000)) {
        $process.Kill()
        throw 'Macro server did not terminate on protocol EOF'
    }
    if ($process.ExitCode -ne 0) { throw "Macro server startup failed: $($process.ExitCode)" }
} finally { $process.Dispose() }
Write-Host "Native macro server built and startup verified: $dist"
