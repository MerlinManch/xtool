import Foundation
import Testing
import XUtils
@testable import XToolSupport

@Test func buildServerConfigurationUsesNativeExecutable() throws {
    let data = Data(LSPConfig.bsp.1.utf8)
    let config = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let arguments = try #require(config["argv"] as? [String])
    #if os(Windows)
    #expect(arguments == ["xtool.exe", "dev", "build-server"])
    #else
    #expect(arguments == ["/usr/bin/env", "xtool", "dev", "build-server"])
    #endif
}

#if os(Windows)
@Test func windowsSearchPathKeepsExistingToolsWithMixedCaseEnvironmentName() {
    let existing = HostPlatform.environmentValue("PATH", in: ["Path": "C:/Swift/bin;C:/Windows/System32"]) ?? ""
    let updated = HostPlatform.prependingSearchPath("C:/SDK/toolset/bin", to: existing)
    #expect(updated == "C:/SDK/toolset/bin;C:/Swift/bin;C:/Windows/System32")
}
#endif

@Test func fileLocksExcludeOtherOpenDescriptors() throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: path) }
    let first = try FileDescriptor.open(FilePath(path.path), .readWrite,
                                        options: [.create], permissions: [.ownerReadWrite])
    var firstIsOpen = true
    defer { if firstIsOpen { try? first.close() } }
    let second = try FileDescriptor.open(FilePath(path.path), .readWrite)
    defer { try? second.close() }
    #expect(try first.tryLock(mode: .exclusive))
    #expect(try !second.tryLock(mode: .exclusive))
    try first.close()
    firstIsOpen = false
    #expect(try second.tryLock(mode: .exclusive))
}
