#if os(Windows)
import Foundation
import WinSDK

extension FileManager {
    private func windowsAttributes(at source: URL) throws -> DWORD {
        let attributes = source.path.withCString(encodedAs: UTF16.self) { GetFileAttributesW($0) }
        guard attributes != INVALID_FILE_ATTRIBUTES else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(GetLastError()))
        }
        return attributes
    }

    package func copyWindowsSymbolicLink(at source: URL, to destination: URL) throws {
        let attributes = try windowsAttributes(at: source)
        let target = try destinationOfSymbolicLink(atPath: source.path)
        let directoryFlag: DWORD = attributes & DWORD(FILE_ATTRIBUTE_DIRECTORY) != 0
            ? DWORD(SYMBOLIC_LINK_FLAG_DIRECTORY) : 0
        let success = destination.path.withCString(encodedAs: UTF16.self) { link in
            target.withCString(encodedAs: UTF16.self) { target in
                if CreateSymbolicLinkW(link, target, directoryFlag | DWORD(SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE)) != 0 {
                    return true
                }
                if GetLastError() == ERROR_INVALID_PARAMETER {
                    return CreateSymbolicLinkW(link, target, directoryFlag) != 0
                }
                return false
            }
        }
        guard success else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(GetLastError())) }
    }

    package func createWindowsHardLink(at source: URL, to destination: URL) throws {
        // Foundation's Windows linkItem creates an absolute symlink. SDK bundles
        // are moved during install/update, so their regular files need NTFS links.
        let success: Bool = destination.path.withCString(encodedAs: UTF16.self) { destination in
            source.path.withCString(encodedAs: UTF16.self) { source in
                if CreateHardLinkW(destination, source, nil) { return true }
                return false
            }
        }
        guard success else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(GetLastError())) }
    }

    package func copyWindowsTree(at source: URL, to destination: URL) throws {
        let attributes = try windowsAttributes(at: source)
        if attributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) != 0 {
            try copyWindowsSymbolicLink(at: source, to: destination)
        } else if attributes & DWORD(FILE_ATTRIBUTE_DIRECTORY) != 0 {
            try createDirectory(at: destination, withIntermediateDirectories: false)
            for child in try contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
                try copyWindowsTree(at: child, to: destination.appendingPathComponent(child.lastPathComponent))
            }
        } else {
            try copyItem(at: source, to: destination)
        }
    }
}
#endif
