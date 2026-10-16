[CmdletBinding()]
param(
    [ValidateSet('debug', 'release')][string]$Configuration = 'release',
    [ValidateSet('x64', 'arm64')][string]$Architecture = 'x64',
    [string]$VcpkgRoot = $env:VCPKG_ROOT,
    # Prefix with native MSVC-compatible OpenSSL, plist, usbmuxd,
    # libimobiledevice-glue and libimobiledevice headers/import libraries/DLLs.
    [string]$NativeDependencyRoot = $env:XTOOL_NATIVE_DEPENDENCIES,
    [switch]$HelpersOnly,
    [switch]$RunTests
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (-not $IsWindows) { throw 'Run this script in PowerShell 7 on native Windows.' }
$root = Split-Path $PSScriptRoot -Parent
$build = Join-Path $PSScriptRoot 'build'
$dist = Join-Path $PSScriptRoot 'dist/bin'

function Invoke-Checked([string]$Program, [string[]]$Arguments) {
    & $Program @Arguments | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "$Program failed with exit code $LASTEXITCODE" }
}

function Initialize-Dependency([string]$Name, [string]$Revision, [string]$RepositoryURL = "") {
    if (-not $RepositoryURL) { $RepositoryURL = "https://github.com/xtool-org/$Name.git" }
    $destination = Join-Path $PSScriptRoot "Dependencies/$Name"
    if (Test-Path $destination) {
        # Refuse to overwrite developer changes on repeated builds.
        $actual = & git -C $destination rev-parse HEAD
        if ($LASTEXITCODE -ne 0 -or $actual -ne $Revision) {
            throw "Unexpected revision in $destination. Move it aside and rebuild."
        }
        Invoke-Checked git @('-C', $destination, 'apply', '--reverse', '--check', (Join-Path $PSScriptRoot "patches/$Name.patch"))
        return
    }
    Invoke-Checked git @('clone', '--no-checkout', $RepositoryURL, $destination)
    Invoke-Checked git @('-C', $destination, 'checkout', '--detach', $Revision)
    Invoke-Checked git @('-C', $destination, 'apply', '--check', (Join-Path $PSScriptRoot "patches/$Name.patch"))
    Invoke-Checked git @('-C', $destination, 'apply', (Join-Path $PSScriptRoot "patches/$Name.patch"))
}

if (-not $VcpkgRoot) { throw 'Pass -VcpkgRoot or set VCPKG_ROOT.' }
$toolchain = Join-Path $VcpkgRoot 'scripts/buildsystems/vcpkg.cmake'
if (-not (Test-Path $toolchain)) { throw "Missing vcpkg CMake toolchain: $toolchain" }
# Hosted runners may have a shallow vcpkg checkout older than our baseline.
$manifest = Get-Content (Join-Path $PSScriptRoot 'vcpkg.json') -Raw | ConvertFrom-Json
$baseline = $manifest.'builtin-baseline'
& git -C $VcpkgRoot cat-file -e "${baseline}:versions/baseline.json" 2>$null
if ($LASTEXITCODE -ne 0) {
    Invoke-Checked git @('-C', $VcpkgRoot, 'fetch', '--depth=1', 'origin', $baseline)
}
# Use a detached worktree for the pinned registry as vcpkg reads version indexes
# from its working HEAD, not merely from objects fetched for builtin-baseline.
$currentVcpkgRevision = & git -C $VcpkgRoot rev-parse HEAD
if ($LASTEXITCODE -ne 0) { throw 'Could not inspect vcpkg revision' }
if ($currentVcpkgRevision -ne $baseline) {
    $pinnedRoot = Join-Path $PSScriptRoot 'Dependencies/vcpkg'
    if (-not (Test-Path $pinnedRoot)) {
        Invoke-Checked git @('-C', $VcpkgRoot, 'worktree', 'add', '--detach', $pinnedRoot, $baseline)
    }
    $actual = & git -C $pinnedRoot rev-parse HEAD
    if ($LASTEXITCODE -ne 0 -or $actual -ne $baseline) { throw 'Pinned vcpkg worktree has an unexpected revision' }
    if (-not (Test-Path (Join-Path $pinnedRoot 'vcpkg.exe'))) {
        Invoke-Checked (Join-Path $pinnedRoot 'bootstrap-vcpkg.bat') @('-disableMetrics')
    }
    $VcpkgRoot = $pinnedRoot
    $toolchain = Join-Path $VcpkgRoot 'scripts/buildsystems/vcpkg.cmake'
}
$cmakeConfiguration = if ($Configuration -eq 'release') { 'Release' } else { 'Debug' }
$triplet = "$Architecture-windows"
New-Item -ItemType Directory -Force $build, $dist | Out-Null
Invoke-Checked cmake @('-S', (Join-Path $PSScriptRoot 'native'), '-B', $build,
    "-DCMAKE_TOOLCHAIN_FILE=$toolchain", "-DVCPKG_TARGET_TRIPLET=$triplet",
    "-DVCPKG_MANIFEST_DIR=$PSScriptRoot", "-DCMAKE_INSTALL_PREFIX=$(Join-Path $PSScriptRoot 'dist')",
    '-A', $(if ($Architecture -eq 'x64') { 'x64' } else { 'ARM64' }))
Invoke-Checked cmake @('--build', $build, '--config', $cmakeConfiguration)
Invoke-Checked cmake @('--install', $build, '--config', $cmakeConfiguration)
# vcpkg app-local deployment places dependent DLLs beside each helper.
Get-ChildItem (Join-Path $build $cmakeConfiguration) -Filter '*.dll' |
    Copy-Item -Destination $dist -Force

if ($HelpersOnly) { return }
if (-not $NativeDependencyRoot) {
    $NativeDependencyRoot = Join-Path $build "vcpkg_installed/$triplet"
}
if (-not (Test-Path (Join-Path $NativeDependencyRoot 'include/libimobiledevice/libimobiledevice.h'))) {
    throw "Native libimobiledevice headers missing in $NativeDependencyRoot"
}
Initialize-Dependency 'xtool-core' 'f867f9c2aea16ac78ca14d0d2f948b47db0732b4'
Initialize-Dependency 'zsign' 'f6158be9e62a5ce2a53d72b1a6d880880da956c8'
Initialize-Dependency 'PathKit' '3bfd2737b700b9a36565a8c94f4ad2b050a5e574' 'https://github.com/kylef/PathKit.git'
Push-Location $root
try {
    $include = Join-Path $NativeDependencyRoot 'include'
    $lib = Join-Path $NativeDependencyRoot 'lib'
    $swiftOptions = @('-c', $Configuration,
        '-Xcc', "-I$include", '-Xcxx', "-I$include", '-Xswiftc', '-I', '-Xswiftc', $include,
        '-Xlinker', "/LIBPATH:$lib")
    # System-library module maps don't specify Windows import-library names.
    foreach ($name in @('libssl', 'libcrypto', 'plist-2.0', 'usbmuxd-2.0', 'imobiledevice-glue-1.0', 'imobiledevice-1.0')) {
        if (-not (Test-Path (Join-Path $lib "$name.lib"))) { throw "Missing native import library $name.lib" }
        $swiftOptions += @('-Xlinker', "$name.lib")
    }
    Invoke-Checked swift (@('build', '--product', 'xtool') + $swiftOptions)
    $binPath = & swift build -c $Configuration --show-bin-path
    if ($LASTEXITCODE -ne 0) { throw 'Could not locate Swift build output.' }
    Copy-Item (Join-Path $binPath 'xtool.exe') $dist -Force
    Invoke-Checked mt.exe @('-nologo', '-manifest', (Join-Path $PSScriptRoot 'xtool.exe.manifest'),
        "-outputresource:$(Join-Path $dist 'xtool.exe');1")
    Get-ChildItem (Join-Path $NativeDependencyRoot 'bin') -Filter '*.dll' | Copy-Item -Destination $dist -Force
    Get-ChildItem $binPath -Filter '*.dll' | Copy-Item -Destination $dist -Force
    if ($RunTests) {
        Invoke-Checked swift (@('test') + $swiftOptions)
        foreach ($command in @('', 'setup', 'auth', 'sdk', 'new', 'dev', 'ds', 'devices', 'install', 'uninstall', 'launch')) {
            $helpArgs = if ($command) { @($command, '--help') } else { @('--help') }
            Invoke-Checked (Join-Path $dist 'xtool.exe') $helpArgs
        }
    }
    Write-Host "Native build output: $dist"
} finally { Pop-Location }
