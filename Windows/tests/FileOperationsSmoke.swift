#if os(Windows)
import Foundation
import WinSDK

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
        defer { try? manager.removeWindowsTree(at: root) }
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
        try manager.removeWindowsTree(at: caseSource)
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
        try manager.removeWindowsTree(at: source)
        try require(try Data(contentsOf: hardLink) == contents, "NTFS hardlink depended on its original path")
        try require(try Data(contentsOf: alias.appendingPathComponent("example.h")) == contents,
                    "Copied SDK still depended on its original tree")
        print("Native Swift file reads, NTFS hardlinks and directory-symlink copying passed")

        // A failed XIP extraction leaves readonly files and links in the
        // temporary SDK. Cleanup must ignore READONLY without mutating another
        // hardlink, traversing directory links, or touching a same-named CWD file.
        let stale = root.appendingPathComponent("darwin.artifactbundle.tmp")
        let nested = stale.appendingPathComponent("Xcode.app/Contents/usr/share/man")
        try manager.createDirectory(at: nested, withIntermediateDirectories: true)
        let protected = nested.appendingPathComponent("Algorithm__Diff.3pm")
        try Data("retained hardlink".utf8).write(to: protected)
        let retained = root.appendingPathComponent("retained.3pm")
        try manager.createWindowsHardLink(at: protected, to: retained)
        try require(protected.path.withCString(encodedAs: UTF16.self) {
            SetFileAttributesW($0, DWORD(FILE_ATTRIBUTE_READONLY))
        }, "Could not make the regression file readonly")
        try manager.createSymbolicLink(atPath: nested.appendingPathComponent("readonly-alias").path,
                                       withDestinationPath: "Algorithm__Diff.3pm")
        try manager.createSymbolicLink(atPath: nested.appendingPathComponent("dangling").path,
                                       withDestinationPath: "missing-target")
        let external = root.appendingPathComponent("external")
        try manager.createDirectory(at: external, withIntermediateDirectories: false)
        let outside = external.appendingPathComponent("keep")
        try Data("outside".utf8).write(to: outside)
        try manager.createSymbolicLink(atPath: stale.appendingPathComponent("directory-link").path,
                                       withDestinationPath: external.path)
        var deep = stale
        for index in 0..<10 {
            deep.appendPathComponent("long Unicode ü path \(index) " + String(repeating: "x", count: 30))
            try manager.createDirectory(at: deep, withIntermediateDirectories: false)
        }
        try Data("long path".utf8).write(to: deep.appendingPathComponent("readonly.3pm"))
        try require(deep.appendingPathComponent("readonly.3pm").path.withCString(encodedAs: UTF16.self) {
            SetFileAttributesW($0, DWORD(FILE_ATTRIBUTE_READONLY))
        }, "Could not make the long-path file readonly")
        let cwd = manager.currentDirectoryPath
        let decoy = root.appendingPathComponent("Algorithm__Diff.3pm")
        try Data("CWD decoy".utf8).write(to: decoy)
        try require(manager.changeCurrentDirectoryPath(root.path), "Could not change regression CWD")
        defer { _ = manager.changeCurrentDirectoryPath(cwd) }
        try manager.removeWindowsTree(at: stale)
        try require(!manager.fileExists(atPath: stale.path), "Failed SDK tree survived cleanup")
        try require(try Data(contentsOf: retained) == Data("retained hardlink".utf8),
                    "Removing SDK changed retained hardlink data")
        let attributes = retained.path.withCString(encodedAs: UTF16.self) { GetFileAttributesW($0) }
        try require(attributes != INVALID_FILE_ATTRIBUTES && attributes & DWORD(FILE_ATTRIBUTE_READONLY) != 0,
                    "Removing SDK changed readonly attributes of retained hardlink")
        try require(try Data(contentsOf: outside) == Data("outside".utf8),
                    "Cleanup traversed an external directory symlink")
        try require(try Data(contentsOf: decoy) == Data("CWD decoy".utf8),
                    "Cleanup touched a relative CWD path")
        try manager.removeWindowsTree(at: caseCopy)
        try require(!manager.fileExists(atPath: caseCopy.path), "Case-distinct files survived cleanup")
        print("Readonly SDK cleanup, retained hardlinks, symlinks, long Unicode paths and CWD isolation passed")

    }
}
#endif
