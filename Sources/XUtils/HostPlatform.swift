import Foundation
#if os(Windows)
import CWindowsSupport
#endif

package enum HostPlatform {
    package static var executableSuffix: String {
        #if os(Windows)
        ".exe"
        #else
        ""
        #endif
    }

    package static func prependingSearchPath(_ path: String, to existing: String) -> String {
        #if os(Windows)
        let separator = ";"
        #else
        let separator = ":"
        #endif
        return existing.isEmpty ? path : path + separator + existing
    }

    package static func bundledTool(_ name: String) throws -> FilePath {
        guard let executable = Bundle.main.executableURL else {
            throw CocoaError(.fileNoSuchFile)
        }
        return FilePath(executable.deletingLastPathComponent()
            .appendingPathComponent(name + executableSuffix).path)
    }

    #if os(Windows)
    package static func installInterruptHandler() throws {
        var error: UInt32 = 0
        guard xtool_install_interrupt_handler(&error) != 0 else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(error))
        }
    }

    package static var interrupted: Bool { xtool_interrupted() != 0 }

    package static func removeInterruptHandler() {
        xtool_remove_interrupt_handler()
    }
    #endif
}
