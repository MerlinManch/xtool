import Foundation
import XKit
import XToolSupport
import Dependencies

@_documentation(visibility: private)
@main
enum XToolMain {
    static func main() async throws {
        prepareDependencies { _ in
            // TODO: Improve persistence mechanism
            // Windows credentials use DPAPI via WindowsProtectedStorage.
            // for Linux, maybe use libsecret?
            // see https://github.com/atom/node-keytar
        }
        try await XTool.run()
    }
}
