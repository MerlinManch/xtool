#if os(Windows)
import Foundation
import XUtils

/// Per-user credential storage protected by Windows DPAPI, without interactive UI.
public struct WindowsProtectedStorage: KeyValueStorage {
    private let storage = DirectoryStorage()
    private static let marker = Data("XTLDPAPI1".utf8)

    public init() {}

    public func data(forKey key: String) throws -> Data? {
        guard let stored = try storage.data(forKey: key) else { return nil }
        if stored.starts(with: Self.marker) {
            return try WindowsDataProtection.unprotect(Data(stored.dropFirst(Self.marker.count)))
        }
        // Migrate credentials written by earlier Windows builds on first access.
        try setData(stored, forKey: key)
        return stored
    }

    public func setData(_ data: Data?, forKey key: String) throws {
        let stored = try data.map { Self.marker + WindowsDataProtection.protect($0) }
        try storage.setData(stored, forKey: key)
    }
}
#endif
