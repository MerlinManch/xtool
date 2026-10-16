#if os(Windows)
import Foundation
import WinSDK

extension FileManager {
    /// Remove a Windows tree without following directory reparse points or
    /// changing attributes shared with retained NTFS hardlinks.
    package func removeWindowsTree(at url: URL) throws {
        let absolute = url.absoluteURL
        let path = absolute.path.replacingOccurrences(of: "/", with: "\\")
        let nativePath: String
        if path.hasPrefix("\\\\?\\") {
            nativePath = path
        } else if path.hasPrefix("\\\\") {
            nativePath = "\\\\?\\UNC\\" + path.dropFirst(2)
        } else {
            nativePath = "\\\\?\\" + path
        }
        func failure(_ code: DWORD) -> NSError {
            NSError(
                domain: NSCocoaErrorDomain,
                code: code == ERROR_FILE_NOT_FOUND || code == ERROR_PATH_NOT_FOUND
                    ? CocoaError.fileNoSuchFile.rawValue : CocoaError.fileWriteUnknown.rawValue,
                userInfo: [
                    NSFilePathErrorKey: absolute.path,
                    NSURLErrorKey: absolute,
                    NSUnderlyingErrorKey: NSError(domain: NSOSStatusErrorDomain, code: Int(code)),
                ]
            )
        }

        let handle = nativePath.withCString(encodedAs: UTF16.self) {
            CreateFileW(
                $0, DWORD(DELETE | FILE_READ_ATTRIBUTES),
                DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE), nil,
                DWORD(OPEN_EXISTING),
                DWORD(FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT), nil
            )
        }
        guard let handle, handle != INVALID_HANDLE_VALUE else { throw failure(GetLastError()) }
        defer { CloseHandle(handle) }
        var info = BY_HANDLE_FILE_INFORMATION()
        guard GetFileInformationByHandle(handle, &info) else { throw failure(GetLastError()) }
        if info.dwFileAttributes & DWORD(FILE_ATTRIBUTE_DIRECTORY) != 0,
           info.dwFileAttributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) == 0 {
            // Enumerate the exact names, including case-distinct SDK entries.
            // Keep this directory open and never traverse junctions or symlinks.
            var entry = WIN32_FIND_DATAW()
            let search = (nativePath + "\\*").withCString(encodedAs: UTF16.self) {
                FindFirstFileW($0, &entry)
            }
            if let search, search != INVALID_HANDLE_VALUE {
                defer { FindClose(search) }
                while true {
                    let name = withUnsafePointer(to: &entry.cFileName) {
                        $0.withMemoryRebound(to: WCHAR.self, capacity: Int(MAX_PATH)) {
                            String(decodingCString: $0, as: UTF16.self)
                        }
                    }
                    if name != ".", name != ".." {
                        try removeWindowsTree(at: absolute.appendingPathComponent(name))
                    }
                    if !FindNextFileW(search, &entry) {
                        let code = GetLastError()
                        guard code == ERROR_NO_MORE_FILES else { throw failure(code) }
                        break
                    }
                }
            } else {
                let code = GetLastError()
                guard code == ERROR_FILE_NOT_FOUND else { throw failure(code) }
            }
        }
        // FILE_DISPOSITION_INFO_EX: DELETE | POSIX_SEMANTICS |
        // IGNORE_READONLY_ATTRIBUTE (Windows 10 1809+). Unlike clearing
        // READONLY then DeleteFileW, this also preserves surviving hardlinks
        // and does not try to change the target of a dangling symlink.
        var flags: DWORD = 0x00000001 | 0x00000002 | 0x00000010
        guard SetFileInformationByHandle(
            handle, FileDispositionInfoEx, &flags, DWORD(MemoryLayout<DWORD>.size)
        ) else { throw failure(GetLastError()) }
    }

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

    private func windowsDirectoryHandle(at url: URL, access: DWORD) throws -> HANDLE {
        let handle = url.path.withCString(encodedAs: UTF16.self) {
            CreateFileW($0, access, DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE),
                        nil, DWORD(OPEN_EXISTING),
                        DWORD(FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT), nil)
        }
        guard let handle, handle != INVALID_HANDLE_VALUE else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(GetLastError()),
                          userInfo: [NSFilePathErrorKey: url.path])
        }
        return handle
    }

    private func windowsDirectoryIsCaseSensitive(at url: URL) throws -> Bool {
        let handle = try windowsDirectoryHandle(at: url, access: DWORD(FILE_READ_ATTRIBUTES))
        defer { CloseHandle(handle) }
        // FILE_CASE_SENSITIVE_INFORMATION contains one ULONG Flags field.
        var flags: DWORD = 0
        guard GetFileInformationByHandleEx(handle, FileCaseSensitiveInfo, &flags, DWORD(MemoryLayout<DWORD>.size)) else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(GetLastError()),
                          userInfo: [NSFilePathErrorKey: url.path])
        }
        return flags & 1 != 0
    }

    package func setWindowsDirectoryCaseSensitive(at url: URL) throws {
        let handle = try windowsDirectoryHandle(at: url, access: DWORD(FILE_READ_ATTRIBUTES | FILE_WRITE_ATTRIBUTES))
        defer { CloseHandle(handle) }
        var flags: DWORD = 1 // FILE_CS_FLAG_CASE_SENSITIVE_DIR
        guard SetFileInformationByHandle(handle, FileCaseSensitiveInfo, &flags, DWORD(MemoryLayout<DWORD>.size)) else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(GetLastError()), userInfo: [
                NSFilePathErrorKey: url.path,
                NSLocalizedDescriptionKey: "Could not enable NTFS case sensitivity for '\(url.path)'. "
                    + "Check directory permissions; enabling the flag may require an elevated terminal.",
            ])
        }
    }

    package func createWindowsDirectory(at destination: URL, preservingCaseOf source: URL) throws {
        try createDirectory(at: destination, withIntermediateDirectories: false)
        if try windowsDirectoryIsCaseSensitive(at: source) {
            try setWindowsDirectoryCaseSensitive(at: destination)
        }
    }

    package func copyWindowsTree(at source: URL, to destination: URL) throws {
        let attributes = try windowsAttributes(at: source)
        if attributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) != 0 {
            try copyWindowsSymbolicLink(at: source, to: destination)
        } else if attributes & DWORD(FILE_ATTRIBUTE_DIRECTORY) != 0 {
            try createWindowsDirectory(at: destination, preservingCaseOf: source)
            for child in try contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
                try copyWindowsTree(at: child, to: destination.appendingPathComponent(child.lastPathComponent))
            }
        } else {
            try copyItem(at: source, to: destination)
        }
    }
}
#endif
