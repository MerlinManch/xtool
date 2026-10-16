# Native signing fixture

`unsigned-macho.zip.base64` contains a tiny unsigned arm64 iOS Mach-O dylib
and its complete C source: `int xtool_add(int a, int b) { return a + b; }`.

Produced on native Windows by `Windows/test-toolset.ps1` and the pinned
LLVM Darwin toolchain, using `-no_adhoc_codesign`. No Apple SDK, credentials,
certificate or private material is included.

Origin: [Windows integration run 38887553184](https://github.com/MerlinManch/xtool/actions/runs/38887553184),
commit `ef4abf0bdb079b23217f8ecb299b1ea5abf77e43`.
The workflow exports this ZIP as base64 for reproducible source fixtures.
The test decodes/extracts it with the native ZIP helper, creates a minimal app,
signs with the native zsign backend and checks the signature and entitlements.

`wwdr-g3.pem` is the public WWDR G3 certificate embedded in the pinned zsign
source. The signing test uses its subject as the issuer name of a synthetic
leaf to exercise zsign's Apple-chain selection. That leaf is locally signed,
not Apple-issued or Apple-trusted. The independent OpenSSL test checks the CMS
signature and rejects tampering without claiming to validate Apple trust.
