[CmdletBinding()]
param(
    [string]$VcpkgRoot = $env:VCPKG_ROOT,
    [int]$Jobs = [Environment]::ProcessorCount,
    [switch]$SkipTests
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (-not $IsWindows) { throw 'Use PowerShell 7 on native Windows.' }
foreach ($program in @('swift', 'cmake', 'git', 'dub', 'ldc2', 'mt.exe')) {
    if (-not (Get-Command $program -ErrorAction SilentlyContinue)) {
        throw "Missing build prerequisite: $program. See Windows/README.md."
    }
}
& (Join-Path $PSScriptRoot 'build.ps1') -VcpkgRoot $VcpkgRoot -RunTests:(-not $SkipTests)
& (Join-Path $PSScriptRoot 'build-anisette.ps1')
& (Join-Path $PSScriptRoot 'build-toolset.ps1') -Jobs $Jobs
if (-not $SkipTests) {
    $env:XTOOL_NATIVE_BIN = Join-Path $PSScriptRoot 'dist/bin'
    $env:XTOOL_NATIVE_TEST_CHILD = Join-Path $PSScriptRoot 'build/Release/xtool-test-child.exe'
    $env:XTOOL_ANISETTE_DLL = Join-Path $PSScriptRoot 'dist/bin/XADIBinary.dll'
    $env:XTOOL_TEST_APPLE_LIBRARIES = '1'
    foreach ($directory in @('tests', 'anisette-tests')) {
        & python -m unittest discover -s (Join-Path $PSScriptRoot $directory) -v
        if ($LASTEXITCODE -ne 0) { throw "Native $directory failed" }
    }
    & (Join-Path $PSScriptRoot 'build/Release/xtool-test-support.exe')
    if ($LASTEXITCODE -ne 0) { throw 'Win32 support tests failed' }
}
& (Join-Path $PSScriptRoot 'package.ps1')
