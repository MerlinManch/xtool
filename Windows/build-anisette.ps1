[CmdletBinding()]
param([string]$Compiler = 'ldc2')
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (-not $IsWindows) { throw 'Use PowerShell 7 on native Windows.' }
$destination = Join-Path $PSScriptRoot 'Dependencies/xadi'
$revision = 'e8f19022f8500eb4cee62145e114041d7ec8afc6'
$patch = Join-Path $PSScriptRoot 'patches/xadi.patch'
function Invoke-Checked([string]$Program, [string[]]$Arguments) {
    & $Program @Arguments | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "$Program failed with exit code $LASTEXITCODE" }
}
if (-not (Test-Path $destination)) {
    Invoke-Checked git @('clone', '--no-checkout', 'https://github.com/xtool-org/xadi.git', $destination)
    Invoke-Checked git @('-C', $destination, 'checkout', '--detach', $revision)
    Invoke-Checked git @('-C', $destination, 'apply', $patch)
} else {
    $actual = & git -C $destination rev-parse HEAD
    if ($LASTEXITCODE -ne 0 -or $actual -ne $revision) { throw "Unexpected source revision at $destination" }
    Invoke-Checked git @('-C', $destination, 'apply', '--reverse', '--check', $patch)
}
Push-Location $destination
try {
    Invoke-Checked dub @('build', '--compiler', $Compiler, '--arch=x86_64', '--config=windows', '--build=release', '--combined')
    $dist = Join-Path $PSScriptRoot 'dist/bin'
    New-Item -ItemType Directory -Force $dist | Out-Null
    Copy-Item (Join-Path $destination 'bin/XADIBinary.dll') $dist -Force
    # Dynamic-loader and D runtime files, if emitted, must remain beside the DLL.
    Get-ChildItem (Join-Path $destination 'bin') -Filter '*.dll' | Copy-Item -Destination $dist -Force
    $licenses = Join-Path $PSScriptRoot 'dist/licenses/xadi'
    New-Item -ItemType Directory -Force $licenses | Out-Null
    Copy-Item (Join-Path $destination 'LICENSE') $licenses -Force
    Copy-Item $patch $licenses -Force
} finally { Pop-Location }
