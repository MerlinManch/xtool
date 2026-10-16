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

$licenseRoot = Join-Path $PSScriptRoot 'dist/licenses'
$nativeLicenses = Join-Path $licenseRoot 'native'
New-Item -ItemType Directory -Force $nativeLicenses | Out-Null
$shared = Join-Path $build "vcpkg_installed/$triplet/share"
foreach ($port in Get-ChildItem $shared -Directory) {
    $copyright = Join-Path $port.FullName 'copyright'
    if (Test-Path $copyright) { Copy-Item $copyright (Join-Path $nativeLicenses "$($port.Name).txt") -Force }
}
Copy-Item (Join-Path $root 'LICENSE.md') (Join-Path $licenseRoot 'xtool.md') -Force

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
Initialize-Dependency 'XcodeProj' 'aeea2e97376cd69fbdd1c7e68664b79a1a641dde' 'https://github.com/tuist/XcodeProj.git'
Initialize-Dependency 'combine-schedulers' '114354e8c1667a2edc4993700fb9fa4f90157b56' 'https://github.com/pointfreeco/combine-schedulers.git'
Initialize-Dependency 'swift-issue-reporting' '75b000cea2ca6d7527a57e1b9cc0bdf21a9abe9f' 'https://github.com/pointfreeco/swift-issue-reporting.git'
Initialize-Dependency 'swift-docc-plugin' '647c708be89f834fa6a6d4945442793a77ddf5b6' 'https://github.com/swiftlang/swift-docc-plugin.git'
Initialize-Dependency 'swift-openapi-generator' '39d49cf22abab58a07f02bb76808b5d2839b294a' 'https://github.com/apple/swift-openapi-generator.git'
# Git for Windows commonly checks out directory symlinks as text placeholders.
# Materialize the shared sources in our prepared dependency, leaving SwiftPM's
# managed checkouts untouched and retaining both DocC commands on Windows.
$docc = Join-Path $PSScriptRoot 'Dependencies/swift-docc-plugin'
foreach ($plugin in @('Swift-DocC Convert', 'Swift-DocC Preview')) {
    $sharedSources = Join-Path $docc "Plugins/$plugin/WindowsSources"
    New-Item -ItemType Directory -Force $sharedSources | Out-Null
    Copy-Item (Join-Path $docc 'Sources/SwiftDocCPluginUtilities') $sharedSources -Recurse -Force
    Copy-Item (Join-Path $docc 'Plugins/SharedPackagePluginExtensions') $sharedSources -Recurse -Force
}
$openapi = Join-Path $PSScriptRoot 'Dependencies/swift-openapi-generator'
foreach ($plugin in @('OpenAPIGenerator', 'OpenAPIGeneratorCommand')) {
    $sharedSources = Join-Path $openapi "Plugins/$plugin/WindowsSources"
    New-Item -ItemType Directory -Force $sharedSources | Out-Null
    foreach ($source in @('Plugins/PluginsShared/PluginError.swift', 'Plugins/PluginsShared/PluginUtils.swift',
        'Sources/_OpenAPIGeneratorCore/GeneratorMode.swift', 'Sources/swift-openapi-generator/PluginSource.swift')) {
        Copy-Item (Join-Path $openapi $source) $sharedSources -Force
    }
}
Push-Location $root
$previousPath = $env:PATH
# SwiftPM runs the test executable in .build, outside the distribution directory.
# Make the same native DLLs available to both test hosts and CLI subprocesses.
$env:PATH = "$dist;$(Join-Path $NativeDependencyRoot 'bin');$previousPath"
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
        Invoke-Checked (Join-Path $dist 'xtool.exe') @('--version')
        $env:XTOOL_NATIVE_BIN = $dist
        $portFile = Join-Path $build 'http-test-port.txt'
        Remove-Item $portFile -ErrorAction SilentlyContinue
        $serverInfo = [System.Diagnostics.ProcessStartInfo]::new('python')
        $serverInfo.UseShellExecute = $false
        $serverInfo.ArgumentList.Add((Join-Path $PSScriptRoot 'cli-tests/http_server.py'))
        $serverInfo.ArgumentList.Add($portFile)
        $server = [System.Diagnostics.Process]::Start($serverInfo)
        try {
            for ($attempt = 0; $attempt -lt 100 -and -not (Test-Path $portFile); $attempt++) {
                if ($server.HasExited) { throw 'Loopback HTTP fixture exited early' }
                Start-Sleep -Milliseconds 100
            }
            if (-not (Test-Path $portFile)) { throw 'Loopback HTTP fixture did not start' }
            $env:XTOOL_HTTP_TEST_URL = "http://127.0.0.1:$((Get-Content $portFile -Raw).Trim())"
            Invoke-Checked swift (@('test') + $swiftOptions)
        } finally {
            if (-not $server.HasExited) { $server.Kill() }
            $server.Dispose()
            Remove-Item Env:XTOOL_HTTP_TEST_URL -ErrorAction SilentlyContinue
            Remove-Item $portFile -ErrorAction SilentlyContinue
        }
        foreach ($command in @('', 'setup', 'auth', 'sdk', 'new', 'dev', 'ds', 'devices', 'install', 'uninstall', 'launch')) {
            $helpArgs = if ($command) { @($command, '--help') } else { @('--help') }
            Invoke-Checked (Join-Path $dist 'xtool.exe') $helpArgs
        }
    }
    if ($RunTests) {
        $env:XTOOL_CLI = Join-Path $dist 'xtool.exe'
        Invoke-Checked python @('-m', 'unittest', 'discover', '-s',
            (Join-Path $PSScriptRoot 'cli-tests'), '-v')
    }
    $swiftLicenses = Join-Path $licenseRoot 'swift'
    foreach ($checkout in Get-ChildItem (Join-Path $root '.build/checkouts') -Directory) {
        $destination = Join-Path $swiftLicenses $checkout.Name
        New-Item -ItemType Directory -Force $destination | Out-Null
        Get-ChildItem $checkout.FullName -File |
            Where-Object { $_.Name -match '^(LICENSE|LICENCE|COPYING|NOTICE)([._-].*)?$' } |
            Copy-Item -Destination $destination -Force
    }
    foreach ($name in @('xtool-core', 'zsign', 'PathKit', 'XcodeProj', 'swift-issue-reporting', 'combine-schedulers', 'swift-docc-plugin', 'swift-openapi-generator')) {
        $destination = Join-Path $licenseRoot $name
        New-Item -ItemType Directory -Force $destination | Out-Null
        Get-ChildItem (Join-Path $PSScriptRoot "Dependencies/$name") -File |
            Where-Object { $_.Name -match '^(LICENSE|LICENCE|COPYING|NOTICE)([._-].*)?$' } |
            Copy-Item -Destination $destination -Force
    }
    Copy-Item (Join-Path $root 'Package.resolved') (Join-Path $PSScriptRoot 'dist/Package.resolved') -Force
    Copy-Item (Join-Path $PSScriptRoot 'patches') $licenseRoot -Recurse -Force
    Write-Host "Native build output: $dist"
} finally {
    $env:PATH = $previousPath
    Pop-Location
}
