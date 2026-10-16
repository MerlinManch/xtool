#if os(Windows)
import Foundation
import WinSDK

@main enum ReadonlyLinkSmoke {
    static func readonlyLink(_ url: URL) throws {
        let handle = url.path.withCString(encodedAs: UTF16.self) {
            CreateFileW($0, DWORD(FILE_WRITE_ATTRIBUTES), DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE),
                        nil, DWORD(OPEN_EXISTING),
                        DWORD(FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT), nil)
        }
        guard let handle, handle != INVALID_HANDLE_VALUE else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(GetLastError()))
        }
        defer { CloseHandle(handle) }
        var info = FILE_BASIC_INFO()
        info.FileAttributes = DWORD(FILE_ATTRIBUTE_READONLY)
        guard SetFileInformationByHandle(handle, FileBasicInfo, &info, DWORD(MemoryLayout<FILE_BASIC_INFO>.size)) else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(GetLastError()))
        }
    }

    static func main() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("xtool readonly symlink ü " + UUID().uuidString)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeWindowsTree(at: root) }
        let outside = root.appendingPathComponent("outside.3pm")
        try Data("retained target".utf8).write(to: outside)
        for name in ["foundation", "native"] {
            let bundle = root.appendingPathComponent(name)
            let nested = bundle.appendingPathComponent("Xcode.app/Contents/usr/share/man")
            try manager.createDirectory(at: nested, withIntermediateDirectories: true)
            let alias = nested.appendingPathComponent("Algorithm__Diff.3pm")
            try manager.createSymbolicLink(atPath: alias.path, withDestinationPath: outside.path)
            try readonlyLink(alias)
            let dangling = nested.appendingPathComponent("dangling.3pm")
            try manager.createSymbolicLink(atPath: dangling.path, withDestinationPath: "absent")
            try readonlyLink(dangling)
            if name == "foundation" {
                do {
                    try manager.removeItem(at: bundle)
                    print("Foundation readonly-symlink cleanup completed")
                } catch {
                    print("Foundation readonly-symlink cleanup diagnostic:", error)
                }
            } else {
                try manager.removeWindowsTree(at: bundle)
                guard !manager.fileExists(atPath: bundle.path) else {
                    throw NSError(domain: "ReadonlyLinkSmoke", code: 1)
                }
            }
        }
        guard try Data(contentsOf: outside) == Data("retained target".utf8) else {
            throw NSError(domain: "ReadonlyLinkSmoke", code: 2)
        }
        print("Native readonly reparse-point and dangling-symlink cleanup passed")
    }
}
#endif
