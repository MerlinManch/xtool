#if os(Windows)
import Foundation

@main enum FileOperationsSmoke {
    struct Failure: Swift.Error, CustomStringConvertible {
        let description: String
    }

    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(description: message) }
    }

    static func main() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("xtool native files ü " + UUID().uuidString)
        defer { try? manager.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let headers = source.appendingPathComponent("Versions/A/Headers")
        try manager.createDirectory(at: headers, withIntermediateDirectories: true)
        let nativeSource = source.path.replacingOccurrences(of: "/", with: "\\")
        var isDirectory: ObjCBool = false
        try require(manager.fileExists(atPath: nativeSource, isDirectory: &isDirectory) && isDirectory.boolValue,
                    "Native Windows input directory detection failed")
        let rawOutput = root.path.replacingOccurrences(of: "/", with: "\\") + "\\raw-output"
        let output = URL(fileURLWithPath: rawOutput, isDirectory: true).appending(path: "darwin.xtoolsdk")
        print("Raw Windows SDK output URL:", output.absoluteString, "path:", output.path)
        do {
            try manager.createDirectory(at: output, withIntermediateDirectories: true)
            print("Raw Windows SDK output directory succeeded")
        } catch { print("Raw Windows SDK output directory diagnostic:", error) }
        print("Native executable URL:", Bundle.main.executableURL?.absoluteString ?? "missing")
        let contents = Data("native SDK header ü 🔐".utf8)
        try contents.write(to: headers.appendingPathComponent("example.h"))
        try manager.createSymbolicLink(atPath: source.appendingPathComponent("Versions/Current").path,
                                       withDestinationPath: "A")
        try manager.createSymbolicLink(atPath: source.appendingPathComponent("Headers").path,
                                       withDestinationPath: "Versions/Current/Headers")
        let input = headers.appendingPathComponent("example.h")
        let handle = try FileHandle(forReadingFrom: input)
        try require(try handle.read(upToCount: 4) == contents.prefix(4), "Native FileHandle read failed")
        try handle.seek(toOffset: 4)
        try require(try handle.readToEnd() == contents.dropFirst(4), "Native FileHandle seek failed")
        try handle.close()
        let caseSource = root.appendingPathComponent("case-source")
        try manager.createDirectory(at: caseSource, withIntermediateDirectories: false)
        try manager.setWindowsDirectoryCaseSensitive(at: caseSource)
        for (directory, text) in [("Headers", "uppercase"), ("headers", "lowercase")] {
            let nested = caseSource.appendingPathComponent(directory)
            try manager.createWindowsDirectory(at: nested, preservingCaseOf: caseSource)
            try Data(text.utf8).write(to: nested.appendingPathComponent("example.h"))
        }
        try Data("upper file".utf8).write(to: caseSource.appendingPathComponent("A.h"))
        try Data("lower file".utf8).write(to: caseSource.appendingPathComponent("a.h"))
        let caseCopy = root.appendingPathComponent("case-copy")
        try manager.copyWindowsTree(at: caseSource, to: caseCopy)
        try manager.removeItem(at: caseSource)
        for (path, text) in [
            ("Headers/example.h", "uppercase"), ("headers/example.h", "lowercase"),
            ("A.h", "upper file"), ("a.h", "lower file"),
        ] {
            try require(try Data(contentsOf: caseCopy.appendingPathComponent(path)) == Data(text.utf8),
                        "Case-distinct SDK copy lost or overwrote " + path)
        }
        print("NTFS case-sensitive directories and case-distinct SDK copies passed")
        // Foundation's directory-copy behavior is logged separately; the SDK
        // uses our explicit Windows tree traversal to retain directory links.
        do {
            try manager.copyItem(at: source, to: root.appendingPathComponent("foundation-copy"))
            print("Foundation directory copy succeeded")
        } catch { print("Foundation directory copy diagnostic:", error) }
        let copy = root.appendingPathComponent("native-copy")
        try manager.copyWindowsTree(at: source, to: copy)
        let alias = copy.appendingPathComponent("Headers")
        try require(try alias.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true,
                    "Copied SDK directory alias is not a symlink")
        try require(try Data(contentsOf: alias.appendingPathComponent("example.h")) == contents,
                    "Copied SDK directory symlink chain is broken")
        let hardLink = root.appendingPathComponent("hardlink.h")
        try manager.createWindowsHardLink(at: input, to: hardLink)
        try manager.removeItem(at: source)
        try require(try Data(contentsOf: hardLink) == contents, "NTFS hardlink depended on its original path")
        try require(try Data(contentsOf: alias.appendingPathComponent("example.h")) == contents,
                    "Copied SDK still depended on its original tree")
        print("Native Swift file reads, NTFS hardlinks and directory-symlink copying passed")
    }
}
#endif
