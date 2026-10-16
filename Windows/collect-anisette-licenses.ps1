[CmdletBinding()]
param(
    [string]$LicenseRoot = (Join-Path $PSScriptRoot 'dist/licenses/xadi'),
    [string]$Compiler = 'ldc2'
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (-not $IsWindows) { throw 'Use PowerShell 7 on native Windows.' }
function Invoke-Checked([string]$Program, [string[]]$Arguments) {
    & $Program @Arguments | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "$Program failed with exit code $LASTEXITCODE" }
}
$buildScript = Get-Content (Join-Path $PSScriptRoot 'build-anisette.ps1') -Raw
$match = [regex]::Match($buildScript, '(?m)^\$revision = ''([0-9a-f]{40})''\r?$')
if (-not $match.Success) { throw 'Cannot identify the pinned Anisette source revision.' }
$revision = $match.Groups[1].Value
$source = Join-Path $PSScriptRoot 'Dependencies/xadi'
$patch = Join-Path $PSScriptRoot 'patches/xadi.patch'
if (-not (Test-Path $source)) {
    Invoke-Checked git @('clone', '--no-checkout', 'https://github.com/xtool-org/xadi.git', $source)
    Invoke-Checked git @('-C', $source, 'checkout', '--detach', $revision)
    Invoke-Checked git @('-C', $source, 'apply', '--check', $patch)
    Invoke-Checked git @('-C', $source, 'apply', $patch)
} else {
    $actual = & git -C $source rev-parse HEAD
    if ($LASTEXITCODE -ne 0 -or $actual -ne $revision) { throw "Unexpected source revision at $source" }
    Invoke-Checked git @('-C', $source, 'apply', '--reverse', '--check', $patch)
}
New-Item -ItemType Directory -Force $LicenseRoot | Out-Null
$LicenseRoot = (Resolve-Path $LicenseRoot).Path
Push-Location $source
try {
    # Describe the exact release configuration without rebuilding its DLL.
    $description = (& dub describe "--compiler=$Compiler" '--arch=x86_64' '--config=windows' '--build=release' '--quiet' | Out-String)
    if ($LASTEXITCODE -ne 0) { throw 'Could not describe the native Anisette dependency graph.' }
    $graph = $description | ConvertFrom-Json
    if (-not $graph.packages.Count) { throw 'Anisette dependency graph contains no packages.' }
    $records = [Collections.Generic.List[object]]::new()
    foreach ($package in $graph.packages) {
        $packageRoot = (Resolve-Path -LiteralPath $package.path).Path
        $name = $package.name -replace '[^A-Za-z0-9._-]', '_'
        $destination = Join-Path $LicenseRoot "dependencies/$name"
        New-Item -ItemType Directory -Force $destination | Out-Null
        $files = @(Get-ChildItem -LiteralPath $packageRoot -Recurse -File | Where-Object {
            $_.Name -match '^(LICENSE|LICENCE|COPYING|NOTICE|COPYRIGHT|AUTHORS)([._-].*)?$'
        })
        if (-not $files.Count) {
            $files = @(Get-ChildItem -LiteralPath $packageRoot -File | Where-Object { $_.Name -match '^README([._-].*)?$' })
        }
        foreach ($file in $files) {
            $relative = [IO.Path]::GetRelativePath($packageRoot, $file.FullName)
            $target = Join-Path $destination $relative
            New-Item -ItemType Directory -Force (Split-Path $target -Parent) | Out-Null
            Copy-Item -LiteralPath $file.FullName -Destination $target -Force
        }
        foreach ($recipe in @('dub.json', 'dub.sdl')) {
            $path = Join-Path $packageRoot $recipe
            if (Test-Path $path -PathType Leaf) { Copy-Item $path $destination -Force }
        }
        $record = [ordered]@{ name = $package.name; licenseFiles = @($files | ForEach-Object {
            [IO.Path]::GetRelativePath($packageRoot, $_.FullName)
        }) }
        foreach ($field in @('version', 'license')) {
            $property = $package.PSObject.Properties[$field]
            if ($null -ne $property) { $record[$field] = $property.Value }
        }
        $records.Add($record)
    }
    $records | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $LicenseRoot 'dependencies.json') -Encoding utf8
    Copy-Item (Join-Path $source 'dub.selections.json') $LicenseRoot -Force
    # Includes the Boost license of the statically linked D runtime and Phobos.
    $compilerPath = (Get-Command $Compiler -CommandType Application).Source
    $compilerRoot = Split-Path (Split-Path $compilerPath -Parent) -Parent
    $compilerLicense = @('LICENSE', 'LICENSE.txt') | ForEach-Object { Join-Path $compilerRoot $_ } |
        Where-Object { Test-Path $_ -PathType Leaf } | Select-Object -First 1
    $runtimeLicense = Join-Path $LicenseRoot 'LDC-runtime.txt'
    if ($compilerLicense) {
        Copy-Item $compilerLicense $runtimeLicense -Force
    } else {
        Invoke-WebRequest 'https://raw.githubusercontent.com/ldc-developers/ldc/v1.43.0/LICENSE' -OutFile $runtimeLicense
    }
    Write-Host "Collected native Anisette dependency licenses for $($records.Count) packages."
} finally { Pop-Location }
