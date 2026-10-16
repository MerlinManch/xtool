# Native Windows port

Native Windows implementation using Swift, MSVC, Win32 and native C/C++/D
libraries. WSL is not used. The complete CLI and SDK toolchain are being validated
on Windows CI; device/account integration also requires an Apple account, Xcode
SDK and an iPhone. This document distinguishes implementation from test coverage.

## Build

Use Windows x64, PowerShell 7, Visual Studio 2022 C++ tools and Windows SDK,
Git, CMake, Python 3, Swift 6.4.1, LDC 1.43.0 with Dub, and vcpkg. Run from a
Visual Studio developer PowerShell session so `mt.exe` and MSVC are available.

```powershell
./Windows/build-all.ps1 -VcpkgRoot C:/src/vcpkg
```

This builds and tests the CLI, archive/linker helpers, device libraries, local
Anisette DLL, LLVM Darwin tools and macro server, then creates
`Windows/xtool-windows-x64.zip`. LLVM is a substantial source build. Sources and
native dependencies are pinned; vcpkg uses a detached worktree at the recorded
baseline instead of changing an existing vcpkg checkout. Build output is in
`Windows/dist`. `-SkipTests` skips the test phase.

Individual components can be built separately:

```powershell
./Windows/build.ps1 -RunTests -VcpkgRoot C:/src/vcpkg
./Windows/build-anisette.ps1
./Windows/build-toolset.ps1
./Windows/package.ps1
```

`build.ps1 -HelpersOnly` builds the native helper executables and device libraries.
An existing MSVC/UCRT native dependency prefix can be selected using
`-NativeDependencyRoot`; the default is the pinned vcpkg build. Import libraries
must include `libssl`, `libcrypto`, `plist-2.0`, `usbmuxd-2.0`,
`imobiledevice-glue-1.0` and `imobiledevice-1.0`. Do not substitute MinGW CRT
libraries. The scripts do not modify SwiftPM checkout caches.
The host CLI is built with SwiftPM's native backend; pass
`-BuildSystem swiftbuild` to `build.ps1` to compare host build backends.

## Run

Keep all files from the distribution together and add its `bin` directory to
PATH. A compatible installed Swift toolchain is required for Swift compilation
and supplies the Swift runtime DLLs; Visual C++ runtime prerequisites also apply.
The executable manifest enables UTF-8 and long paths.

```powershell
xtool.exe --help
xtool.exe sdk install C:/Downloads/Xcode.xip
xtool.exe auth login
xtool.exe devices
```

Enable Windows Developer Mode or symlink privileges and long paths. Use NTFS and
a case-sensitive SDK directory where Xcode SDK contents require names differing
only by case. USB requires Apple Mobile Device Support and a running Apple Mobile
Device Service. Trust this computer on the iPhone and enable iOS Developer Mode
where required by the upstream instructions.

Build a Windows-host SDK from Xcode.xip or Xcode.app. A Linux-host SDK contains
ELF executables and cannot be reused. Native tool resources default to
`windows-toolset` and `windows-macros` beside xtool.exe. Override these with
`XTOOL_WINDOWS_TOOLSET` and `XTOOL_WINDOWS_MACROS`. The installer checks PE headers
and host architecture. The XIP helper extracts the archive; it does not verify
Apple's XIP signature. Apple does not supply an iOS Simulator runtime for Windows;
macOS simulator commands retain their upstream platform restrictions.

## Implementation

| Area | Windows implementation |
| --- | --- |
| Processes | swift-subprocess, `.exe` resolution, PATH separator and Windows exit status |
| Console | Win32 Unicode input, password echo restoration, UTF-8 redirected input |
| Cancellation | Ctrl+C/Ctrl+Break control handler and cooperative task cancellation |
| Temporary files | Nonblocking LockFileEx coordination and close-before-delete cleanup |
| Credentials | Per-user Windows DPAPI protection and plaintext-storage migration |
| IPA | Native libarchive helper, hidden files, links, Mach-O executable-mode reconstruction |
| Xcode.xip | Streaming XAR/PBZX/XZ/CPIO extraction with bounded chunk memory |
| Darwin linking | Native response-file trampoline, LLVM linker and Apple librarian |
| SDK | Windows triples and native LLVM/macros tools, `.exe` tool paths |
| IDE/BSP | Native executable invocation and Windows environment handling |
| Signing | Native OpenSSL/zsign and patched Windows directory enumeration |
| Device operations | Native libplist, usbmuxd, libimobiledevice and SwiftyMobileDevice |
| Local Anisette | Native XADIBinary.dll, Windows/SysV ABI thunk, local Apple-library initialization |
| Developer Services | Shared authentication, provisioning, teams, certificates, identifiers, profiles and app groups |

## Validation

Independent Windows workflows build/test the CLI and native dependencies,
the Anisette runtime, the macro server and the SDK host tools. Separating them avoids restarting
the long LLVM build when a CLI or Anisette fix changes.

Verified so far:

- Native Windows Anisette DLL builds and passes export/error-boundary tests.
  The public Apple Music APK's x86_64 libraries initialize successfully; Android
  ID and provisioning-directory calls cross the ABI boundary. Complete anonymous
  Apple provisioning and local OTP generation also pass; no Apple ID is used.
- 20 native helper tests and the Win32 lock/DPAPI tests pass on Windows.
  The archive suite also passes on Linux: response-file forwarding, exit status,
  raw/compressed PBZX, Unicode, hard/symbolic links, executable modes, malformed
  archives, traversal and symlink escapes. Directory symlinks and forward
  link chains are covered in both XIP and IPA extraction.
  Long SDK/IPA paths and linker invocation with a bare program name also pass.
- The native LLVM linker, Apple librarian and dsymutil build from the pinned
  fork on Windows. The native macro server also builds and passes startup/
  protocol-EOF verification.
  Real Windows integration produces an arm64 iOS Mach-O dylib, an Apple static
  archive and Mach-O DWARF debug symbols, including the linker's `-r` routing.
  The macro server also passes a real compiler-protocol handshake, module loading,
  SwiftUI `@Entry` expansion with Unicode content and unknown-module diagnostics.
- The complete CLI compiles and links on native Windows with Swift optimization
  disabled for diagnostics. The optimized release build and complete runtime
  test suite are still in progress.
- Windows PathKit branches pass semantic compilation and functional normalization/
  glob checks using Swift 6.4.1; Windows integration tests are included.
- Windows-target syntax parsing passes for 131 non-generated Swift source files.
- Repository SwiftLint completes with zero violations.

Pending Windows CI results and integration coverage:

- Optimized CLI build and `swift test`, HTTP/WebSocket loopback tests, project
  creation/redirected console tests and a synthetic Windows SDK integration test.
- Real Xcode SDK install/update/remove and example compilation including
  SwiftUI macros and SwiftBuild/BSP.
- Apple ID/2FA, ASC keys, account provisioning and real-device USB/network
  signing/install/launch/uninstall. These require external credentials/hardware.
- ARM64 support is not release-validated; the complete build targets x64 and the
  local Anisette implementation currently uses Apple's x86_64 libraries.

A passing helper or Anisette build alone is not evidence of full feature parity.
