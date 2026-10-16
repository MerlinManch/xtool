# Native Windows port — implementation and validation status

This branch adds a native Windows implementation without WSL or a Linux subprocess.
**It is not yet a verified complete Windows release.** No full Swift build or real
Windows/iPhone integration run was possible in the implementation environment.
The native device library dependency prefix is not bundled or built by this branch.

Base: MerlinManch/xtool, commit `316a11e`.

## Implemented

| Area | Native Windows implementation | Verification |
| --- | --- | --- |
| Process execution | Enable swift-subprocess on Windows; handle Windows exit status | Swift compilation pending |
| Console/passwords | Win32 console modes; restore echo; UTF-8; redirected line input | Windows integration pending |
| Ctrl+C/Ctrl+Break | Win32 control handler plus cooperative task cancellation | C tests supplied; Windows execution pending |
| Temporary directory coordination | Nonblocking LockFileEx and close-before-delete cleanup | C/Swift tests supplied; Windows execution pending |
| IPA creation/extraction | libarchive helper, symlinks and hidden files; reconstruct Mach-O executable permissions on NTFS | Linux native helper tests pass |
| Xcode.xip | Streaming XAR → PBZX/XZ → CPIO extraction with bounded memory | Linux native helper tests pass |
| Linker | Native executable replaces the shell trampoline; arguments, UTF-8/UTF-16 response files and exit codes | Linux native helper tests pass |
| Darwin SDK | Windows triples, .exe tools, Windows LLVM/macros resources, host architecture validation | Full SDK build pending |
| IDE/BSP | Native xtool.exe invocation; Windows PATH separator | Swift test supplied; execution pending |
| HTTP | FoundationNetworking imports and Security-only TLS API guard | Windows HTTPS/WebSocket tests pending |
| Signing dependencies | Pinned xtool-core and zsign patches for Windows build issues and directory enumeration | Windows signing integration pending |
| Device/Developer Services commands | Existing command implementations retained | Authentication, provisioning, USB, install, launch, uninstall pending |

The Windows ADI selection uses the existing Omnisette provider. Native local XADI
is not ported; this is a remaining functional difference from Linux/macOS. The
original Linux/macOS XADI dependency remains platform-limited.

## Prerequisites

- Native Windows 10/11, PowerShell 7, Git, CMake and Visual Studio 2022 C++ build tools.
- A compatible native Swift toolchain (package minimum 6.2; SwiftBuild/BSP requires
  6.4 in the existing code). The macro package's own toolchain requirements apply.
- A Visual Studio developer PowerShell session, including `mt.exe` on PATH.
- vcpkg; pass its root to the build script.
- Developer Mode / symlink privileges for SDK and app framework links. Use NTFS,
  enable long paths, and use a case-sensitive SDK directory where SDK contents
  require distinct names differing only by case. No lossy symlink fallback exists.
- Apple Mobile Device Support and a running Apple Mobile Device Service for USB.
  Trust the computer on the device. Device-specific Developer Mode requirements
  from upstream xtool continue to apply.

## Build the native helpers

```powershell
./Windows/build.ps1 -HelpersOnly -VcpkgRoot C:/src/vcpkg
$env:XTOOL_NATIVE_BIN = "$pwd/Windows/dist/bin"
$env:XTOOL_NATIVE_TEST_CHILD = "$pwd/Windows/build/Release/xtool-test-child.exe"
python -m unittest discover -s Windows/tests -v
./Windows/build/Release/xtool-test-support.exe
```

The helper workflow `.github/workflows/windows-native.yml` runs these checks on
Windows and uploads helper executables. It does **not** build/test the full Swift
CLI and has not been dispatched from the implementation environment.

## Build the CLI

Provide a prefix containing **native MSVC/UCRT-compatible** dependencies, with:

- `include/`: OpenSSL, libplist, libusbmuxd, libimobiledevice-glue and libimobiledevice headers;
- `lib/`: `libssl.lib`, `libcrypto.lib`, `plist-2.0.lib`, `usbmuxd-2.0.lib`,
  `imobiledevice-glue-1.0.lib`, `imobiledevice-1.0.lib`;
- `bin/`: their runtime DLLs and all transitive DLL dependencies.

The versions must expose the APIs used by SwiftyMobileDevice 1.7.0. Alternate
library names can be normalized by copying their import libraries under the names
above. Do not substitute MinGW libraries using a different CRT: allocated memory
crosses the Swift/C library boundary. Creating, supplying and validating this
native device-library distribution remains required to finish the port.

```powershell
./Windows/build.ps1 -VcpkgRoot C:/src/vcpkg -NativeDependencyRoot C:/src/ios-native
./Windows/dist/bin/xtool.exe --help
```

The build script checks out the exact upstream revisions and applies the reviewed
patches from `Windows/patches`. It does not edit SwiftPM checkout caches or remote
branches. Runtime prerequisites from the installed Swift toolchain must be on PATH.
The executable manifest enables UTF-8 for the legacy C/Win32 signing paths.

## Build the SDK host tools

```powershell
./Windows/build-toolset.ps1
./Windows/dist/bin/xtool.exe sdk install C:/Downloads/Xcode.xip
```

The script builds the same pinned LLVM fork used by darwin-tools-linux-llvm 1.1.0
and OpenAppleMacros 1.3.0 as native Windows programs. This is a substantial LLVM
source build. Run it for the host architecture; ARM64 output is not validated.
The native builds themselves remain unverified here.

Alternatively provide `XTOOL_WINDOWS_TOOLSET` (directory with `bin/ld64.lld.exe`,
`bin/llvm-libtool-darwin.exe`, `bin/dsymutil.exe`, and required DLLs), and
`XTOOL_WINDOWS_MACROS` (directory containing `OpenAppleMacrosServer.exe` and its
DLLs). By default the installer uses `windows-toolset` and `windows-macros`
subdirectories beside xtool.exe. ELF/Linux executables are rejected.

Rebuild the SDK for Windows. A Linux-built SDK contains Linux tools and should not
be reused as a Windows host SDK. SDK metadata uses a Windows-specific version.
The XIP helper extracts contents; it does not authenticate Apple's XIP signature.

## Validation still required for completion

1. Build the entire CLI and run `swift test` with a native Windows Swift toolchain
   and the dependency prefix; resolve any remaining transitive platform errors.
2. Run the helper workflow on Windows, including UTF-8, symlinks, file locks and
   argument forwarding. Run the repository's `make lint` in a supported Swift host.
3. Build/install/update/remove an SDK from real Xcode.xip in normal and slim modes;
   compile all examples, including SwiftUI macros and the SwiftBuild/BSP path.
4. Exercise Apple ID/2FA and ASC key authentication; teams, certificates, devices,
   identifiers, profiles and app groups with real service credentials.
5. Test signing and USB/network deployment, launch/debug and uninstall on real iOS
   devices. Validate the installed app and extension executable permissions.
6. Implement/validate a local Windows ADI provider for parity with local XADI.

## Checks performed in this environment

- C++17 compilation of linker, XIP and ZIP helper with GCC `-Wall -Wextra -Werror`.
- 15 functional tests passed on Linux against native libarchive/liblzma: argument
  forwarding/exit status, raw/compressed PBZX, exact chunk boundaries, Unicode,
  hard/symbolic links, IPA round trip and executable modes, invalid/truncated data,
  path traversal and symlink escapes.
- `swift build` / `swift test`: blocked (`swift: command not found`).
- `make lint`: attempted; SwiftLint could not load `libsourcekitdInProc.so` because
  there is no installed Swift toolchain.
- No Windows build, real Xcode SDK build, Apple service login or iPhone test run.
