#if os(Windows)
import Foundation
import Testing
import PathKit
import XUtils

@Test func windowsDriveAndUNCRootsSurviveNormalization() {
    #expect(Path("C:\\work\\..\\file").normalize().string == "C:/file")
    #expect((Path("C:/") + "../../../file").string == "C:/file")
    #expect(Path("//server/share/..").normalize().string == "//server/share")
    #expect((Path("C:/work") + "D:/file").string == "D:/file")
    #expect(Path("C:/file").isAbsolute)
    #expect(!Path("work/file").isAbsolute)
}

@Test func windowsGlobbingSupportsBracesRangesAndHiddenFiles() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    for name in ["a1.txt", "b2.swift", ".hidden.txt"] {
        try Data().write(to: directory.appendingPathComponent(name))
    }
    let root = Path(directory.path)
    #expect(root.glob("*.{txt,swift}").map(\.lastComponent).sorted() == ["a1.txt", "b2.swift"])
    #expect(root.glob("[ab][0-9].*").map(\.lastComponent).sorted() == ["a1.txt", "b2.swift"])
    #expect(root.glob(".hidden.*").map(\.lastComponent) == [".hidden.txt"])
    #expect(Path("a1.txt").match("[a-c]?.txt"))
    #expect(!Path("a1.txt").match("[!a]*"))
}

@Test func windowsDPAPIRoundTrip() throws {
    for original in [Data(), Data("credentials ü 🔐".utf8)] {
        let encrypted = try WindowsDataProtection.protect(original)
        #expect(encrypted != original)
        #expect(try WindowsDataProtection.unprotect(encrypted) == original)
    }
}
@Test func windowsSDKCopiesPreserveDirectoryLinksAndHardLinksSurviveRelocation() async throws {
    let manager = FileManager.default
    let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try manager.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: root) }
    let source = root.appendingPathComponent("source")
    let target = source.appendingPathComponent("Z-target")
    try manager.createDirectory(at: target, withIntermediateDirectories: true)
    try Data("original".utf8).write(to: target.appendingPathComponent("file"))
    try manager.createSymbolicLink(atPath: source.appendingPathComponent("A-link").path,
                                   withDestinationPath: "Z-target")
    let copy = root.appendingPathComponent("copy")
    try await manager.copyItem(at: source, to: copy, preserveOwner: false)
    #expect(try manager.destinationOfSymbolicLink(atPath: copy.appendingPathComponent("A-link").path) == "Z-target")
    #expect(try Data(contentsOf: copy.appending(path: "A-link/file")) == Data("original".utf8))
    let link = root.appendingPathComponent("hard-link")
    try manager.createWindowsHardLink(at: target.appendingPathComponent("file"), to: link)
    let moved = root.appendingPathComponent("moved")
    try manager.moveItem(at: source, to: moved)
    try Data("updated".utf8).write(to: moved.appending(path: "Z-target/file"))
    #expect(try Data(contentsOf: link) == Data("updated".utf8))
}
#endif
