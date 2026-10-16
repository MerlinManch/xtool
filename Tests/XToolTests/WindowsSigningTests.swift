#if os(Windows)
import Foundation
import CryptoExtras
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
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
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
    let app = root.appendingPathComponent("Fixture.app")
    try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
    let executable = app.appendingPathComponent("Fixture")
    try FileManager.default.moveItem(at: root.appendingPathComponent("library.dylib"), to: executable)
    let info: [String: Any] = [
        "CFBundleIdentifier": "com.example.xtool.native-fixture",
        "CFBundleExecutable": "Fixture",
        "CFBundleName": "Fixture",
        "CFBundlePackageType": "APPL",
        "CFBundleVersion": "1",
        "CFBundleSupportedPlatforms": ["iPhoneOS"],
        "MinimumOSVersion": "17.0",
    ]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        .write(to: app.appendingPathComponent("Info.plist"))
    let unsigned = try Data(contentsOf: executable)
    #expect(nativeMachOSignature(unsigned) == nil)
    let signer = try Signer.first()
    #expect(await signer.name == "zsign")
    let entitlements = try Entitlements(entitlements: [])
    let identity: Signer.Identity
    let certificateData: Data?
    if certificateSigning {
        let key = try _RSA.Signing.PrivateKey(keySize: .bits2048)
        let name = try DistinguishedName { CommonName("xtool native Windows signing test") }
        let now = Date()
        let raw = try X509.Certificate(
            version: .v3, serialNumber: .init(bytes: [1]), publicKey: .init(key.publicKey),
            notValidBefore: now - 60, notValidAfter: now + 3600,
            issuer: name, subject: name, signatureAlgorithm: .sha256WithRSAEncryption,
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
    }
    #expect(FileManager.default.fileExists(atPath: app.appendingPathComponent("_CodeSignature/CodeResources").path))
    let extracted = try await signer.analyze(executable: executable)
    #expect(try PropertyListSerialization.propertyList(from: extracted, format: nil) is [String: Any])
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
