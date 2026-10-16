#if os(Windows)
import Foundation
import CryptoExtras
import Crypto
import Subprocess
import SystemPackage
import Testing
import XKit
import XUtils
import X509

@Test(
    .enabled(if: ProcessInfo.processInfo.environment["XTOOL_NATIVE_BIN"] != nil),
    .timeLimit(.minutes(1)), arguments: [false, true]
)
func windowsNativeSigningAndAnalysis(certificateSigning: Bool) async throws {
    let helpers = try #require(ProcessInfo.processInfo.environment["XTOOL_NATIVE_BIN"])
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: temporary) }
    var root = temporary.appendingPathComponent("native signing ü 🔏")
    for index in 0..<6 {
        root.appendPathComponent("long-directory-\(index)-" + String(repeating: "x", count: 42))
    }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    #expect(root.path.count > 300)
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/unsigned-macho.zip.base64")
    let encoded = try String(contentsOf: fixture, encoding: .utf8)
    let archive = try #require(Data(base64Encoded: encoded, options: .ignoreUnknownCharacters))
    let zip = root.appendingPathComponent("fixture.zip")
    try archive.write(to: zip)
    try await Subprocess.run(
        .path(FilePath(URL(fileURLWithPath: helpers).appendingPathComponent("xtool-zip.exe").path)),
        arguments: ["extract", zip.path, root.path],
        output: .currentStandardOutput,
        error: .currentStandardError
    ).checkSuccess()
    let unsigned = try Data(contentsOf: root.appendingPathComponent("library.dylib"))
    let app = root.appendingPathComponent("Ü App.app")
    let outer = app.appendingPathComponent("Frameworks/Outer.framework")
    let inner = outer.appendingPathComponent("Frameworks/Inner.framework")
    let executable = try makeNativeSigningBundle(at: app, executableData: unsigned, identifier: "com.example.xtool.fixture")
    _ = try makeNativeSigningBundle(at: outer, executableData: unsigned, identifier: "com.example.xtool.fixture.outer")
    _ = try makeNativeSigningBundle(at: inner, executableData: unsigned, identifier: "com.example.xtool.fixture.inner")
    let resource = app.appendingPathComponent("Resources/über🔏.txt")
    let resourceData = Data("native Unicode resource 🔏".utf8)
    try FileManager.default.createDirectory(at: resource.deletingLastPathComponent(), withIntermediateDirectories: true)
    try resourceData.write(to: resource)
    #expect(nativeMachOSignature(unsigned) == nil)
    let signer = try Signer.first()
    #expect(await signer.name == "zsign")
    let entitlements = try Entitlements(entitlements: [])
    let identity: Signer.Identity
    let certificateData: Data?
    if certificateSigning {
        let key = try _RSA.Signing.PrivateKey(keySize: .bits2048)
        let name = try DistinguishedName {
            CommonName("xtool native Windows signing test")
            OrganizationalUnitName("XTOOLTEST1")
        }
        // Synthetic leaf: exercise Apple's issuer-chain selection and CMS
        // construction, without claiming an Apple-issued or trusted identity.
        let issuerPEM = try String(contentsOf: fixture.deletingLastPathComponent()
            .appendingPathComponent("wwdr-g3.pem"), encoding: .utf8)
        let issuer = try X509.Certificate(pemEncoded: issuerPEM).subject
        let now = Date()
        let raw = try X509.Certificate(
            version: .v3, serialNumber: .init(bytes: [1]), publicKey: .init(key.publicKey),
            notValidBefore: now - 60, notValidAfter: now + 3600,
            issuer: issuer, subject: name, signatureAlgorithm: .sha256WithRSAEncryption,
            extensions: .init(), issuerPrivateKey: .init(key)
        )
        let certificate = try XKit.Certificate(raw: raw)
        identity = .real(certificate, XKit.PrivateKey(data: Data(key.pemRepresentation.utf8)))
        certificateData = try certificate.data()
    } else {
        identity = .adhoc
        certificateData = nil
    }
    try await signer.sign(app: app, identity: identity, entitlementMapping: [app: entitlements]) { _ in }
    let signed = try Data(contentsOf: executable)
    #expect(signed != unsigned)
    let signature = try #require(nativeMachOSignature(signed))
    #expect(Array(signature.prefix(4)) == [0xfa, 0xde, 0x0c, 0xc0])
    if let certificateData {
        _ = try #require(signature.range(of: Data([0xfa, 0xde, 0x0b, 0x01])))
        _ = try #require(signature.range(of: certificateData))
        try await verifyNativeCMS(signature, in: temporary)
    }
    try verifyNativeResource(in: app, path: "Resources/über🔏.txt", data: resourceData)
    let innerExecutable = inner.appendingPathComponent("Über🔏")
    let nestedData = try Data(contentsOf: innerExecutable)
    _ = try #require(nativeMachOSignature(nestedData))
    try verifyNativeResource(in: outer, path: "Frameworks/Inner.framework/Über🔏", data: nestedData)
    let extracted = try await signer.analyze(executable: executable)
    #expect(try PropertyListSerialization.propertyList(from: extracted, format: nil) is [String: Any])
}

private func makeNativeSigningBundle(at app: URL, executableData: Data, identifier: String) throws -> URL {
    try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
    let executable = app.appendingPathComponent("Über🔏")
    try executableData.write(to: executable)
    let info: [String: Any] = [
        "CFBundleIdentifier": identifier,
        "CFBundleExecutable": "Über🔏",
        "CFBundleName": app.deletingPathExtension().lastPathComponent,
        "CFBundlePackageType": app.pathExtension == "app" ? "APPL" : "FMWK",
        "CFBundleVersion": "1",
        "CFBundleSupportedPlatforms": ["iPhoneOS"],
        "MinimumOSVersion": "17.0",
    ]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        .write(to: app.appendingPathComponent("Info.plist"))
    return executable
}

private func verifyNativeResource(in app: URL, path: String, data: Data) throws {
    let resources = try Data(contentsOf: app.appendingPathComponent("_CodeSignature/CodeResources"))
    let manifest = try #require(PropertyListSerialization.propertyList(from: resources, format: nil) as? [String: Any])
    let entries = try #require(manifest["files2"] as? [String: Any])
    let entry = try #require(entries[path] as? [String: Any])
    #expect(entry["hash2"] as? Data == Data(SHA256.hash(data: data)))
}

private func verifyNativeCMS(_ signature: Data, in root: URL) async throws {
    let verifier = try #require(ProcessInfo.processInfo.environment["XTOOL_NATIVE_CMS_VERIFIER"])
    let directory = try #require(nativeSignatureSlot(signature, type: 0))
    let cms = try #require(nativeSignatureSlot(signature, type: 0x10000))
    let cmsURL = root.appendingPathComponent("signature.cms")
    let directoryURL = root.appendingPathComponent("code-directory.bin")
    try cms.dropFirst(8).write(to: cmsURL)
    try directory.write(to: directoryURL)
    try await Subprocess.run(
        .path(FilePath(verifier)), arguments: .init([cmsURL.path, directoryURL.path]),
        output: .discarded, error: .currentStandardError
    ).checkSuccess()
    var damaged = directory
    damaged[damaged.count - 1] ^= 1
    try damaged.write(to: directoryURL)
    let rejection = try await Subprocess.run(
        .path(FilePath(verifier)), arguments: .init([cmsURL.path, directoryURL.path]),
        output: .discarded, error: .discarded
    )
    #expect(!rejection.terminationStatus.isSuccess)
}

private func nativeSignatureSlot(_ data: Data, type: UInt32) -> Data? {
    guard data.count >= 12 else { return nil }
    func word(_ offset: Int) -> UInt32 {
        data.withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
    }
    let count = Int(word(8))
    guard count <= (data.count - 12) / 8 else { return nil }
    for index in 0..<count where word(12 + index * 8) == type {
        let offset = Int(word(16 + index * 8))
        guard offset <= data.count - 8 else { return nil }
        let length = Int(word(offset + 4))
        guard length >= 8, length <= data.count - offset else { return nil }
        return data.subdata(in: offset..<(offset + length))
    }
    return nil
}

private func nativeMachOSignature(_ data: Data) -> Data? {
    guard data.count >= 32 else { return nil }
    func word(_ offset: Int) -> UInt32 {
        data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
    }
    guard word(0) == 0xfeedfacf else { return nil }
    var cursor = 32
    for _ in 0..<word(16) {
        guard cursor <= data.count - 8 else { return nil }
        let size = Int(word(cursor + 4))
        guard size >= 8, size <= data.count - cursor else { return nil }
        if word(cursor) == 0x1d {
            guard size >= 16 else { return nil }
            let offset = Int(word(cursor + 8))
            let length = Int(word(cursor + 12))
            guard length > 0, offset <= data.count, length <= data.count - offset else { return nil }
            return data.subdata(in: offset..<(offset + length))
        }
        cursor += size
    }
    return nil
}
#endif
