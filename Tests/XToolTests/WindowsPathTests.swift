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
#endif
