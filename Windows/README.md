# Native Windows port

Native Windows implementation using Swift, MSVC, Win32 and native C/C++/D
libraries. WSL is not used. The optimized x64 CLI, native dependencies and SDK
host tools build and pass their Windows test suites. Account/device integration
requires an Apple account, a real Xcode SDK and an iPhone; that coverage is listed
separately below.

## Build

Use Windows 10/11 x64, PowerShell 7, Visual Studio 2022 C++ tools and Windows SDK,
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
PATH. The distribution bundles Swift runtime DLLs beside each executable,
including the macro server. A compatible installed Swift toolchain is required
for Swift compilation, but not for `xtool.exe --help`. The Microsoft Visual C++
2015–2022 Redistributable (x64) must be installed.
The executable manifest enables UTF-8 and long paths.

```powershell
xtool.exe --help
xtool.exe sdk install C:/Downloads/Xcode.xip
xtool.exe auth login
xtool.exe devices
```

If an older package exits without output, run `./xtool.exe --help` followed
immediately by `$LASTEXITCODE`. Exit code `-1073741515` (`0xC0000135`) means
Windows could not load a required DLL. Replace the complete extracted package
with a current distribution; do not copy only `xtool.exe`. If necessary, install
the x64 Visual C++ Redistributable from Microsoft's official site. Other exit
codes need separate diagnosis.

Enable Windows Developer Mode or symlink privileges and long paths. Use
local NTFS storage for SDKs. The XIP extractor enables case sensitivity on each
Xcode directory before writing its contents, and SDK install/update preserves it.
This retains case-distinct headers and hardlinked manpages such as
`circleq_init.3` and `CIRCLEQ_INIT.3`. If Windows refuses the flag change, check
NTFS directory permissions and retry from an elevated PowerShell terminal. USB requires Apple Mobile Device Support and a running Apple Mobile
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
| Signing | Native OpenSSL/zsign, Unicode/long-path I/O, nested framework sealing and thread-safe mappings |
| Device operations | Native libplist, usbmuxd, libimobiledevice and SwiftyMobileDevice |
| Local Anisette | Native XADIBinary.dll, Windows/SysV ABI thunk, local Apple-library initialization |
| Networking | Native WinHTTP HTTP/TLS/WebSockets, streaming downloads, redirects, cookies, gzip, proxy tunnels and cancellation |
| Developer Services | Shared authentication, provisioning, teams, certificates, identifiers, profiles and app groups |

## Validation

Independent Windows workflows build/test the CLI and native dependencies,
the Anisette runtime, the macro server and the SDK host tools. Separating them avoids restarting
the long LLVM build when a CLI or Anisette fix changes.

Verified on native Windows:

- The complete CLI builds and links with release optimization. Both optimized
  and diagnostic builds pass the Swift test suite; tests requiring Xcode on
  macOS retain their platform-specific skip condition.
- 24 archive/linker tests pass: response-file forwarding, exit status,
  raw/compressed PBZX, Unicode, hard/symbolic links, executable modes, malformed
  archives, traversal, symlink escapes, forward directory-link chains and long
  SDK/IPA paths, plus case-distinct directories, symlinks and CPIO hardlinks.
  Additional CPIO cases cover read-only hardlinks with payloads in the first,
  last or every link entry. Windows read-only file modes are applied after all
  payloads have been written. IPA symlink targets retain UTF-8 and POSIX separators.
- 11 native WinHTTP tests pass: fragmented/empty WebSocket messages, failed
  upgrades, HTTP POST/streaming, duplicate headers, redirects, gzip, cookie
  isolation, TLS WebSockets, HTTPS proxy tunnels and cancellation. Additional
  certificate roots remain private to the client; untrusted, expired and
  wrong-host certificates are rejected before HTTP data is sent.
- Swift integration reaches the real `gsa.apple.com` and
  `developerservices2.apple.com` HTTPS endpoints without credentials.
- Signing tests create ad-hoc and RSA certificate signatures on genuine arm64
  Mach-O fixtures in long Unicode paths. Nested frameworks and resource hashes
  are verified. An independent OpenSSL verifier checks the detached CMS
  signature and rejects a changed CodeDirectory; mismatched signing keys
  produce an error. The synthetic test certificate is not Apple-issued.
- Console tests verify Unicode password input and restored echo. DPAPI tests
  cover encryption, migration, corruption rejection and removal. File tests
  verify locks, hardlinks and relocated directory-link chains.
- CLI integration creates projects, checks native BSP configuration, accepts
  redirected UTF-8 input and builds/installs/updates/removes a synthetic SDK on
  NTFS. Source Xcode metadata remains unchanged. SDK cleanup uses native deletion
  handles with absolute long paths, without following directory symlinks or
  clearing read-only attributes shared with surviving hardlinks. Regression
  fixtures include interrupted extraction, read-only manpages, dangling links,
  case-distinct names and long Unicode paths.
- Native LLVM tools compile C and Swift Builtin code into arm64 iOS Mach-O,
  link dylibs, create Apple static archives and produce DWARF debug symbols.
  The real `-r` trampoline is exercised with the native Apple librarian.
- The macro server passes compiler-protocol negotiation, module loading,
  Unicode SwiftUI `@Entry` expansion and unknown-module diagnostics. The same
  tests pass through the executable symlink used by installed SDKs.
- The native Anisette DLL passes C-to-D export/error-boundary tests. Apple's
  x86_64 libraries initialize; complete anonymous Apple provisioning and local
  OTP generation pass without an Apple ID.
- Repository `make lint` and PowerShell syntax checks pass.

### Command coverage

| Commands | Windows implementation and validation boundary |
| --- | --- |
| `setup` | Native SDK/authentication components; complete setup needs the user's SDK/account |
| `auth login/status/logout` | Native console, WinHTTP, Anisette and DPAPI; account/2FA needs live credentials |
| `sdk build/install/update/remove/status` | Native archive/tools/file operations; synthetic lifecycle passes, real Xcode integration remains external |
| `new` | Project creation, UTF-8 input and native BSP configuration pass |
| `dev build/run` | Native Swift, LLVM, macros and deployment libraries; a full app build/run needs a real SDK/device |
| `dev xcode` | Shared Xcode project generator and Windows PathKit/XcodeProj dependencies |
| `dev build-server` | Native executable/environment forwarding; BSP configuration is tested |
| `ds teams/certificates/identifiers/devices/profiles/anisette` | Shared API operations over native networking/crypto; account mutations need live credentials |
| `devices/install/uninstall/launch` | Native libimobiledevice/usbmuxd stack; USB/network device checks need hardware |

### Remaining external validation

- Install/update/remove a real Xcode SDK and compile an example app, including
  SwiftUI macros and SwiftBuild/BSP, against that SDK.
- Apple ID/2FA, ASC keys, account provisioning and real-device USB/network
  signing/install/launch/uninstall.
- Native ARM64 is not provided by this x64 distribution. The local Anisette
  implementation uses Apple's x86_64 libraries.
- Apple's iOS Simulator runtime is macOS-only; simulator commands retain the
  upstream macOS restriction.

Automated CI success does not establish end-to-end feature parity for hardware,
credentials or proprietary SDK content that was not available to the runners.

## Distribution

The `Native Windows distribution` workflow combines successful, source-compatible
CLI, native-helper, Anisette and SDK-tool artifacts. It validates the x64 PE files, includes
component revisions, resolved dependencies and licenses, runs the assembled CLI,
and publishes `xtool-windows-x64.zip` with a SHA-256 checksum. Runtime import
closures and hashes are recorded in `runtime-files.json`. Before archiving, the
CLI must produce help/version output with only Windows System32 on PATH, from
an unrelated working directory. The macro protocol and installed-SDK symlink
tests also run in that environment. The assembled archive helpers must pass the
XIP/IPA suite, including the case-distinct Xcode manpage regression, before the
ZIP is published. The assembled CLI also removes read-only SDK trees and
cleans an interrupted extraction before validating the next install input,
with only Windows System32 on PATH.
