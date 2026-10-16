[CmdletBinding()]
param([string]$ToolsetRoot = (Join-Path $PSScriptRoot 'dist/bin/windows-toolset'))
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (-not $IsWindows) { throw 'Use PowerShell 7 on native Windows.' }
function Invoke-Checked([string]$Program, [string[]]$Arguments) {
    & $Program @Arguments | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "$Program failed with exit code $LASTEXITCODE" }
}
$root = Split-Path $PSScriptRoot -Parent
$work = Join-Path $PSScriptRoot 'build/toolset-test'
$bin = Join-Path $work 'bin'
New-Item -ItemType Directory -Force $work, $bin, (Join-Path $bin 'orig') | Out-Null
$swift = (Get-Command swiftc.exe).Source
$clang = Join-Path (Split-Path $swift -Parent) 'clang.exe'
$object = Join-Path $work 'object with spaces.o'
$source = Join-Path $work 'source.c'
'int xtool_add(int a, int b) { return a + b; }' | Set-Content $source -Encoding utf8
Invoke-Checked $clang @('-target', 'arm64-apple-ios17.0', '-g', '-O0', '-ffreestanding',
    '-nostdinc', '-fno-stack-protector', '-c', $source, '-o', $object)
# Exercise Swift's real Darwin code generator without an Apple SDK or runtime.
# Builtin integer operations need no standard library; UIKit/SwiftUI builds still
# require the user's Xcode SDK.
$swiftSource = Join-Path $work 'source.swift'
$swiftObject = Join-Path $work 'swift object.o'
@'
import Builtin
@_silgen_name("xtool_swift_add")
public func xtool_swift_add(_ a: Builtin.Int64, _ b: Builtin.Int64) -> Builtin.Int64 {
    return Builtin.add_Int64(a, b)
}
'@ | Set-Content $swiftSource -Encoding utf8
Invoke-Checked $swift @('-frontend', '-parse-stdlib', '-nostdimport', '-target', 'arm64-apple-ios17.0',
    '-emit-object', '-module-name', 'XToolDarwinProbe', $swiftSource, '-o', $swiftObject)
Invoke-Checked (Join-Path $ToolsetRoot 'bin/ld64.lld.exe') @('-arch', 'arm64', '-dylib', '-no_adhoc_codesign',
    '-platform_version', 'ios', '17.0', '27.0', '-install_name', '@rpath/swift-library.dylib',
    '-o', (Join-Path $work 'swift-library.dylib'), $swiftObject)
$library = Join-Path $work 'library.dylib'
Invoke-Checked (Join-Path $ToolsetRoot 'bin/ld64.lld.exe') @('-arch', 'arm64', '-dylib', '-no_adhoc_codesign',
    '-platform_version', 'ios', '17.0', '27.0', '-install_name', '@rpath/library.dylib', '-o', $library, $object)
Invoke-Checked (Join-Path $ToolsetRoot 'bin/dsymutil.exe') @('--flat', '-o', (Join-Path $work 'library.dwarf'), $library)
Invoke-Checked (Join-Path $ToolsetRoot 'bin/llvm-libtool-darwin.exe') @('-static', '-o', (Join-Path $work 'library.a'), $object)
# Exercise the real linker/librarian behind the relocatable-link trampoline too.
Copy-Item (Join-Path $ToolsetRoot 'bin/ld64.lld.exe') (Join-Path $bin 'orig/ld64.lld.exe') -Force
Copy-Item (Join-Path $ToolsetRoot 'bin/llvm-libtool-darwin.exe') (Join-Path $bin 'llvm-lib.exe') -Force
Invoke-Checked cl.exe @('/nologo', '/std:c++17', '/EHsc', '/W4', '/WX',
    (Join-Path $root 'Windows/native/linker.cpp'), "/Fe$(Join-Path $bin 'ld64.lld.exe')", "/Fo$(Join-Path $work 'linker.obj')")
$fileList = Join-Path $work 'file list.txt'
$object | Set-Content $fileList -Encoding utf8
Invoke-Checked (Join-Path $bin 'ld64.lld.exe') @('-r', '-filelist', $fileList,
    '-dependency_info', (Join-Path $work 'dependency.dat'), '-o', (Join-Path $work 'combined.o'))
foreach ($name in @('library.a', 'combined.o')) {
    $bytes = [System.IO.File]::ReadAllBytes((Join-Path $work $name))
    if ([System.Text.Encoding]::ASCII.GetString($bytes, 0, 8) -ne "!<arch>`n") {
        throw "Not an Apple static archive: $name"
    }
}
foreach ($name in @('library.dylib', 'library.dwarf', 'swift-library.dylib', 'swift object.o')) {
    $bytes = [System.IO.File]::ReadAllBytes((Join-Path $work $name))
    if ($bytes.Length -lt 4 -or [BitConverter]::ToString($bytes, 0, 4) -ne 'CF-FA-ED-FE') {
        throw "Not an arm64 Mach-O: $name"
    }
}
Write-Host 'Native Windows Darwin compilation, linking, archiving and debug-symbol generation passed'
$env:XTOOL_NATIVE_MACRO_SERVER = Join-Path (Split-Path $ToolsetRoot -Parent) 'windows-macros/OpenAppleMacrosServer.exe'
Invoke-Checked python @('-m', 'unittest', 'discover', '-s', (Join-Path $PSScriptRoot 'macro-tests'), '-v')
