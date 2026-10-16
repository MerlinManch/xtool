#if os(Windows)
import Dependencies
import Foundation
import Testing
import XKit

@Test func windowsCredentialsEncryptMigrateAndRemove() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try withDependencies {
        $0.persistentDirectory = root
    } operation: {
        let protected = WindowsProtectedStorage()
        let disk = DirectoryStorage()
        let marker = Data("XTLDPAPI1".utf8)
        let secret = Data("native Windows secret ü 🔐\u{0}".utf8)
        try protected.setData(secret, forKey: "credential")
        let encrypted = try #require(try disk.data(forKey: "credential"))
        #expect(encrypted.starts(with: marker))
        #expect(encrypted != secret)
        #expect(try protected.data(forKey: "credential") == secret)

        let legacy = Data("legacy credential".utf8)
        try disk.setData(legacy, forKey: "credential")
        #expect(try protected.data(forKey: "credential") == legacy)
        let migrated = try #require(try disk.data(forKey: "credential"))
        #expect(migrated.starts(with: marker))
        #expect(migrated != legacy)
        #expect(try protected.data(forKey: "credential") == legacy)

        // Corrupt protected records must never be returned as plaintext.
        let corrupt = marker + Data([1, 2, 3])
        try disk.setData(corrupt, forKey: "credential")
        do {
            _ = try protected.data(forKey: "credential")
            Issue.record("Expected DPAPI to reject the corrupt credential")
        } catch {}
        #expect(try disk.data(forKey: "credential") == corrupt)
        try protected.setData(nil, forKey: "credential")
        #expect(try protected.data(forKey: "credential") == nil)
    }
}
#endif
