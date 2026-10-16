#if os(Windows)
import Foundation
import CWindowsSupport

package enum WindowsDataProtection {
    package static func protect(_ data: Data) throws -> Data {
        try transform(data, protect: true)
    }

    package static func unprotect(_ data: Data) throws -> Data {
        try transform(data, protect: false)
    }

    private static func transform(_ data: Data, protect: Bool) throws -> Data {
        guard let size = UInt32(exactly: data.count) else {
            throw CocoaError(.fileReadTooLarge)
        }
        var output: UnsafeMutableRawPointer?
        var outputSize: UInt32 = 0
        var error: UInt32 = 0
        let result = data.withUnsafeBytes { input in
            if protect {
                return xtool_protect_data(input.baseAddress, size, &output, &outputSize, &error)
            } else {
                return xtool_unprotect_data(input.baseAddress, size, &output, &outputSize, &error)
            }
        }
        guard result != 0 else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(error))
        }
        defer { xtool_release_secret(output, outputSize) }
        if outputSize == 0 { return Data() }
        guard let output else { throw CocoaError(.fileReadCorruptFile) }
        return Data(bytes: output, count: Int(outputSize))
    }
}
#endif
