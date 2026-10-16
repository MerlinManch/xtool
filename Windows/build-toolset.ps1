[CmdletBinding()]
param(
    [ValidateSet('x64', 'arm64')][string]$Architecture = 'x64',
    [int]$Jobs = [Environment]::ProcessorCount
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (-not $IsWindows) { throw 'Use PowerShell 7 on native Windows.' }
$dependencies = Join-Path $PSScriptRoot 'Dependencies'
$toolset = Join-Path $PSScriptRoot 'dist/bin/windows-toolset/bin'
$macros = Join-Path $PSScriptRoot 'dist/bin/windows-macros'
New-Item -ItemType Directory -Force $dependencies, $toolset, $macros | Out-Null

function Invoke-Checked([string]$Program, [string[]]$Arguments) {
    & $Program @Arguments | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "$Program failed with exit code $LASTEXITCODE" }
}
function Checkout-Pinned([string]$Name, [string]$URL, [string]$Revision) {
    $destination = Join-Path $dependencies $Name
    if (-not (Test-Path $destination)) {
        Invoke-Checked git @('clone', '--filter=blob:none', '--no-checkout', '--depth=1', $URL, $destination)
        Invoke-Checked git @('-C', $destination, 'fetch', '--depth=1', 'origin', $Revision)
        Invoke-Checked git @('-C', $destination, 'checkout', '--detach', $Revision)
    }
    $actual = & git -C $destination rev-parse HEAD
    if ($LASTEXITCODE -ne 0 -or $actual -ne $Revision) { throw "Unexpected source revision at $destination" }
    $dirty = & git -C $destination status --porcelain --untracked-files=no
    if ($LASTEXITCODE -ne 0 -or $dirty) { throw "Source modifications found at $destination" }
    return $destination
}
# The same LLVM fork/revision used by darwin-tools-linux-llvm v1.1.0.
$llvm = Checkout-Pinned 'llvm-project' 'https://github.com/kabiroberai/llvm-project.git' '7ae80f745b07d2c99733b09dccf27bf68a1b271c'
$llvmBuild = Join-Path $PSScriptRoot 'build/llvm'
Invoke-Checked cmake @('-S', (Join-Path $llvm 'llvm'), '-B', $llvmBuild,
    '-A', $(if ($Architecture -eq 'x64') { 'x64' } else { 'ARM64' }),
    '-DLLVM_INCLUDE_TESTS=OFF', '-DLLVM_ENABLE_PROJECTS=lld', '-DLLVM_TARGETS_TO_BUILD=AArch64;X86')
Invoke-Checked cmake @('--build', $llvmBuild, '--config', 'Release', '--parallel', "$Jobs",
    '--target', 'lld', 'dsymutil', 'llvm-libtool-darwin')
$llvmBin = Join-Path $llvmBuild 'Release/bin'
Copy-Item (Join-Path $llvmBin 'lld.exe') (Join-Path $toolset 'ld64.lld.exe') -Force
foreach ($name in @('dsymutil.exe', 'llvm-libtool-darwin.exe')) {
    Copy-Item (Join-Path $llvmBin $name) (Join-Path $toolset $name) -Force
}
Get-ChildItem $llvmBin -Filter '*.dll' | Copy-Item -Destination $toolset -Force

$macroSource = Checkout-Pinned 'OpenAppleMacros' 'https://github.com/xtool-org/OpenAppleMacros.git' '4078c0e615d288134fb2453f02616135b2b94d1b'
Invoke-Checked swift @('build', '--package-path', $macroSource, '-c', 'release', '--product', 'OpenAppleMacrosServer')
$macroBin = & swift build --package-path $macroSource -c release --show-bin-path
if ($LASTEXITCODE -ne 0) { throw 'Could not locate macro server build output' }
Copy-Item (Join-Path $macroBin 'OpenAppleMacrosServer.exe') $macros -Force
Get-ChildItem $macroBin -Filter '*.dll' | Copy-Item -Destination $macros -Force
Write-Host "Native Windows toolset and macro sources built into $(Split-Path $toolset -Parent) and $macros"
