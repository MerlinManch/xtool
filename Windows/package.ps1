[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (-not $IsWindows) { throw 'Use PowerShell 7 on native Windows.' }
$root = Split-Path $PSScriptRoot -Parent
$dist = Join-Path $PSScriptRoot 'dist'
$bin = Join-Path $dist 'bin'
$required = @('xtool.exe', 'XADIBinary.dll', 'xtool-linker.exe', 'xtool-codesign.exe',
    'xtool-zip.exe', 'xtool-unxip.exe', 'windows-toolset/bin/ld64.lld.exe',
    'windows-toolset/bin/llvm-libtool-darwin.exe', 'windows-toolset/bin/dsymutil.exe',
    'windows-macros/OpenAppleMacrosServer.exe')
foreach ($file in $required) {
    if (-not (Test-Path (Join-Path $bin $file) -PathType Leaf)) { throw "Incomplete distribution: missing $file" }
}
$licenses = Join-Path $dist 'licenses'
New-Item -ItemType Directory -Force $licenses | Out-Null
Copy-Item (Join-Path $root 'LICENSE.md') (Join-Path $licenses 'xtool.txt') -Force
# vcpkg supplies copyright files including transitive native dependencies.
$shared = Join-Path $PSScriptRoot 'build/vcpkg_installed/x64-windows/share'
if (-not (Test-Path $shared)) { throw 'Missing native dependency license directory' }
foreach ($dependency in Get-ChildItem $shared -Directory) {
    $copyright = Join-Path $dependency.FullName 'copyright'
    if (Test-Path $copyright) {
        Copy-Item $copyright (Join-Path $licenses ($dependency.Name + '.txt')) -Force
    }
}
foreach ($dependency in @('xtool-core', 'zsign', 'PathKit', 'XcodeProj', 'swift-issue-reporting', 'llvm-project', 'OpenAppleMacros')) {
    $source = Join-Path $PSScriptRoot "Dependencies/$dependency"
    $license = @('LICENSE', 'LICENSE.txt', 'LICENSE.md', 'llvm/LICENSE.TXT') |
        ForEach-Object { Join-Path $source $_ } | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $license) { throw "Missing source license for $dependency" }
    Copy-Item $license (Join-Path $licenses "$dependency.txt") -Force
}
# Include licenses of Swift packages linked into the CLI and macro server.
foreach ($checkoutRoot in @((Join-Path $root '.build/checkouts'),
    (Join-Path $PSScriptRoot 'Dependencies/OpenAppleMacros/.build/checkouts'))) {
    if (-not (Test-Path $checkoutRoot)) { continue }
    foreach ($checkout in Get-ChildItem $checkoutRoot -Directory) {
        $destination = Join-Path $licenses "swift/$($checkout.Name)"
        New-Item -ItemType Directory -Force $destination | Out-Null
        Get-ChildItem $checkout.FullName -File | Where-Object {
            $_.Name -match '^(LICENSE|LICENCE|COPYING|NOTICE)([._-].*)?$'
        } | Copy-Item -Destination $destination -Force
    }
}
if (-not (Test-Path (Join-Path $licenses 'xadi/LICENSE'))) {
    throw 'Missing XADI license and native runtime build record; run build-anisette.ps1'
}
Copy-Item (Join-Path $root 'Package.resolved') $dist -Force
Copy-Item (Join-Path $PSScriptRoot 'README.md') (Join-Path $dist 'README.md') -Force
$revision = & git -C $root rev-parse HEAD
if ($LASTEXITCODE -ne 0) { throw 'Cannot identify packaged source revision' }
$components = @{}
foreach ($name in @('xtool-core', 'zsign', 'PathKit', 'XcodeProj', 'swift-issue-reporting', 'xadi', 'llvm-project', 'OpenAppleMacros')) {
    $componentRevision = & git -C (Join-Path $PSScriptRoot "Dependencies/$name") rev-parse HEAD
    if ($LASTEXITCODE -ne 0) { throw "Cannot identify $name source revision" }
    $components[$name] = $componentRevision
}
$components['vcpkg'] = (Get-Content (Join-Path $PSScriptRoot 'vcpkg.json') -Raw | ConvertFrom-Json).'builtin-baseline'
@{
    components = $components
    repository = 'https://github.com/MerlinManch/xtool'
    revision = $revision
    architecture = 'x86_64-unknown-windows-msvc'
    swift = (& swift --version | Out-String).Trim()
} | ConvertTo-Json | Set-Content (Join-Path $dist 'build-info.json') -Encoding utf8
$archive = Join-Path $PSScriptRoot 'xtool-windows-x64.zip'
Compress-Archive -Path (Join-Path $dist '*') -DestinationPath $archive -Force
Get-FileHash $archive -Algorithm SHA256 | Format-List
Write-Host "Native Windows distribution: $archive"
