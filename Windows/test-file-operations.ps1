$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$build = Join-Path $PSScriptRoot 'build'
New-Item -ItemType Directory -Force $build | Out-Null
$executable = Join-Path $build 'FileOperationsSmoke.exe'
& swiftc -package-name xtool (Join-Path $root 'Sources/XUtils/WindowsFileOperations.swift') `
    (Join-Path $PSScriptRoot 'tests/FileOperationsSmoke.swift') -o $executable
if ($LASTEXITCODE -ne 0) { throw 'Native file-operation smoke test compilation failed' }
& $executable
if ($LASTEXITCODE -ne 0) { throw 'Native Swift file-operation smoke test failed' }

$linkExecutable = Join-Path $build 'ReadonlyLinkSmoke.exe'
& swiftc -package-name xtool (Join-Path $root 'Sources/XUtils/WindowsFileOperations.swift') `
    (Join-Path $PSScriptRoot 'file-operation-tests/ReadonlyLinkSmoke.swift') -o $linkExecutable
if ($LASTEXITCODE -ne 0) { throw 'Readonly reparse-point regression compilation failed' }
& $linkExecutable
if ($LASTEXITCODE -ne 0) { throw 'Readonly reparse-point cleanup failed' }
