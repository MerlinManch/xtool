[CmdletBinding()]
param(
    [string]$InputRoot = (Join-Path $PSScriptRoot 'package-input'),
    [string]$OutputRoot = (Join-Path $PSScriptRoot 'delivery/xtool-windows-x64'),
    [string]$Metadata = (Join-Path $PSScriptRoot 'component-builds.json')
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (-not $IsWindows) { throw 'Use PowerShell 7 on native Windows.' }
if (Test-Path $OutputRoot) { throw "Output already exists: $OutputRoot" }
if (-not (Test-Path $Metadata -PathType Leaf)) { throw 'Component build metadata is required.' }
$builds = Get-Content $Metadata -Raw | ConvertFrom-Json
foreach ($component in @('cli', 'helpers', 'sdk', 'anisette')) {
    $record = $builds.$component
    if (-not $record.head_sha -or -not $record.run_id -or -not $record.artifact_id -or -not $record.digest) {
        throw "Incomplete build provenance for $component"
    }
    if (-not (Test-Path (Join-Path $InputRoot $component) -PathType Container)) {
        throw "Missing component artifact: $component"
    }
}
New-Item -ItemType Directory -Force $OutputRoot | Out-Null
Copy-Item (Join-Path $InputRoot 'cli/*') $OutputRoot -Recurse -Force
Copy-Item (Join-Path $InputRoot 'helpers/*') $OutputRoot -Recurse -Force
Copy-Item (Join-Path $InputRoot 'anisette/*') $OutputRoot -Recurse -Force
$bin = Join-Path $OutputRoot 'bin'
Copy-Item (Join-Path $InputRoot 'sdk/*') $bin -Recurse -Force
# Deploy Swift's transitive DLL imports for every executable, including the
# separately located macro server. The developer machine's PATH hid missing
# runtime files in the original distribution.
& python (Join-Path $PSScriptRoot 'bundle-runtime.py') $OutputRoot
if ($LASTEXITCODE -ne 0) { throw 'Runtime DLL deployment failed' }
$required = @('xtool.exe', 'XADIBinary.dll', 'xtool-linker.exe', 'xtool-codesign.exe',
    'xtool-zip.exe', 'xtool-unxip.exe', 'windows-toolset/bin/ld64.lld.exe',
    'windows-toolset/bin/llvm-libtool-darwin.exe', 'windows-toolset/bin/dsymutil.exe',
    'windows-macros/OpenAppleMacrosServer.exe')
foreach ($name in $required) {
    if (-not (Test-Path (Join-Path $bin $name) -PathType Leaf)) { throw "Incomplete distribution: $name" }
}
# Validate every bundled program and DLL, including transitive native dependencies.
foreach ($file in Get-ChildItem $bin -Recurse -File | Where-Object { $_.Extension -in @('.exe', '.dll') }) {
    $stream = [IO.File]::OpenRead($file.FullName)
    $reader = [IO.BinaryReader]::new($stream)
    try {
        if ($stream.Length -lt 64 -or $reader.ReadUInt16() -ne 23117) { throw "Invalid DOS header: $file" }
        $stream.Position = 60
        $offset = $reader.ReadUInt32()
        if ($offset -gt $stream.Length - 6) { throw "Invalid PE offset: $file" }
        $stream.Position = $offset
        if ($reader.ReadUInt32() -ne 17744 -or $reader.ReadUInt16() -ne 34404) {
            throw "Expected native x64 PE program: $file"
        }
    } finally { $reader.Dispose() }
}
$licenses = Join-Path $OutputRoot 'licenses'
foreach ($requiredLicense in @('native', 'swift', 'xadi/LICENSE', 'patches')) {
    if (-not (Test-Path (Join-Path $licenses $requiredLicense))) {
        throw "Missing component licenses: $requiredLicense"
    }
}
# These exact source revisions are pinned by build-toolset.ps1 and checked by
# the assembly workflow against the CLI source before artifacts are combined.
$sourceLicenses = @{
    'llvm-project.txt' = 'https://raw.githubusercontent.com/kabiroberai/llvm-project/7ae80f745b07d2c99733b09dccf27bf68a1b271c/llvm/LICENSE.TXT'
    'OpenAppleMacros.txt' = 'https://raw.githubusercontent.com/xtool-org/OpenAppleMacros/4078c0e615d288134fb2453f02616135b2b94d1b/LICENSE.md'
    'OpenAppleMacros-swift-syntax.txt' = 'https://raw.githubusercontent.com/swiftlang/swift-syntax/050f1a346fbbac0ca2cfb15a95274f7bd1cf0ccf6/LICENSE.txt'
    'LDC-runtime.txt' = 'https://raw.githubusercontent.com/ldc-developers/ldc/v1.43.0/LICENSE'
    'Swift-runtime.txt' = 'https://raw.githubusercontent.com/swiftlang/swift/swift-6.4.1-RELEASE/LICENSE.txt'
    'Swift-Foundation-runtime.txt' = 'https://raw.githubusercontent.com/swiftlang/swift-corelibs-foundation/swift-6.4.1-RELEASE/LICENSE'
    'Swift-Foundation-Essentials-runtime.txt' = 'https://raw.githubusercontent.com/swiftlang/swift-foundation/swift-6.4.1-RELEASE/LICENSE.md'
    'Swift-Foundation-Essentials-NOTICE.txt' = 'https://raw.githubusercontent.com/swiftlang/swift-foundation/swift-6.4.1-RELEASE/NOTICE.txt'
    'Swift-Dispatch-runtime.txt' = 'https://raw.githubusercontent.com/swiftlang/swift-corelibs-libdispatch/swift-6.4.1-RELEASE/LICENSE'
    'Swift-ICU-runtime.txt' = 'https://raw.githubusercontent.com/swiftlang/swift-foundation-icu/swift-6.4.1-RELEASE/LICENSE.md'
}
foreach ($name in $sourceLicenses.Keys) {
    Invoke-WebRequest $sourceLicenses[$name] -OutFile (Join-Path $licenses $name)
}
Copy-Item $Metadata (Join-Path $OutputRoot 'component-builds.json') -Force
Copy-Item (Join-Path $PSScriptRoot 'README.md') (Join-Path $OutputRoot 'README.md') -Force
& python (Join-Path $PSScriptRoot 'bundle-runtime.py') $OutputRoot --smoke
if ($LASTEXITCODE -ne 0) { throw 'Clean-environment runtime checks failed' }
foreach ($argument in @('--version', '--help')) {
    & (Join-Path $bin 'xtool.exe') $argument
    if ($LASTEXITCODE -ne 0) { throw "Assembled CLI failed $argument" }
}
# Exercise the actual assembled host tools, macro server and Anisette DLL.
$vswhere = "${env:ProgramFiles(x86)}/Microsoft Visual Studio/Installer/vswhere.exe"
$vs = & $vswhere -latest -property installationPath
Import-Module "$vs/Common7/Tools/Microsoft.VisualStudio.DevShell.dll"
Enter-VsDevShell -VsInstallPath $vs -SkipAutomaticLocation -DevCmdArguments '-arch=x64 -host_arch=x64'
$previousMacro = $env:XTOOL_NATIVE_MACRO_SERVER
$previousAnisette = $env:XTOOL_ANISETTE_DLL
$previousNativeBin = $env:XTOOL_NATIVE_BIN
try {
    # Exercise the archive helpers from the assembled distribution, including
    # Xcode's case-distinct CPIO hardlinks, before publishing this ZIP.
    $env:XTOOL_NATIVE_BIN = $bin
    & python -m unittest discover -s (Join-Path $PSScriptRoot 'tests') -p test_native_tools.py -k XIPTests -k ZIPTests -v
    if ($LASTEXITCODE -ne 0) { throw 'Assembled archive helper regression tests failed' }
    & python -m unittest discover -s (Join-Path $PSScriptRoot 'xip-regression-tests') -v
    if ($LASTEXITCODE -ne 0) { throw 'Assembled CPIO permissions and payload tests failed' }
    & (Join-Path $PSScriptRoot 'test-toolset.ps1') -ToolsetRoot (Join-Path $bin 'windows-toolset')
    $env:XTOOL_ANISETTE_DLL = Join-Path $bin 'XADIBinary.dll'
    & python -m unittest discover -s (Join-Path $PSScriptRoot 'anisette-tests') -p test_anisette_runtime.py -v
    if ($LASTEXITCODE -ne 0) { throw 'Assembled Anisette DLL checks failed' }
} finally {
    $env:XTOOL_NATIVE_MACRO_SERVER = $previousMacro
    $env:XTOOL_ANISETTE_DLL = $previousAnisette
    $env:XTOOL_NATIVE_BIN = $previousNativeBin
}
$archive = "$OutputRoot.zip"
Compress-Archive -Path (Join-Path $OutputRoot '*') -DestinationPath $archive -Force
$hash = (Get-FileHash $archive -Algorithm SHA256).Hash.ToLowerInvariant()
"$hash  $([IO.Path]::GetFileName($archive))" | Set-Content "$archive.sha256" -Encoding ascii
Write-Host "Native Windows distribution: $archive"
Write-Host "SHA256: $hash"
