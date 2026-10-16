import Foundation
#if os(Windows)
import CWindowsSupport
#endif

#if canImport(System)
import System

public typealias FilePath = System.FilePath
public typealias FileDescriptor = System.FileDescriptor
public typealias Errno = System.Errno
#else
import SystemPackage

public typealias FilePath = SystemPackage.FilePath
public typealias FileDescriptor = SystemPackage.FileDescriptor
public typealias Errno = SystemPackage.Errno

extension URL {
    public init?(filePath: FilePath) {
        self.init(filePath: filePath.string)
    }
}

extension FilePath {
    public init?(_ url: URL) {
        guard url.isFileURL else { return nil }
        self.init(url.path)
    }
}
#endif

extension FileDescriptor {
    package enum LockMode: Equatable {
        case shared
        case exclusive

        #if !os(Windows)
        fileprivate var raw: CInt {
            switch self {
            case .shared: LOCK_SH
            case .exclusive: LOCK_EX
            }
        }
        #endif
    }

    package func tryLock(mode: LockMode) throws -> Bool {
        #if os(Windows)
        var error: UInt32 = 0
        let result = xtool_try_lock(rawValue, mode == .exclusive ? 1 : 0, &error)
        guard result >= 0 else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(error))
        }
        return result == 1
        #else
        if flock(rawValue, mode.raw | LOCK_NB) == 0 {
            return true
        }
        let err = errno
        if err == EWOULDBLOCK {
            return false
        }
        throw Errno(rawValue: err)
        #endif
    }
}
