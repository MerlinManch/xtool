import Foundation
import XKit
import Dependencies
import PackLib
import Subprocess
import XUtils

extension ZIPCompressor: DependencyKey {

    public static let liveValue = ZIPCompressor(
        compress: { dir, progress in
            progress(nil)

            let dest = dir.deletingLastPathComponent().appendingPathComponent("app.ipa")

            #if os(Windows)
            // Restore executable bits for Mach-O files on NTFS and keep symlinks.
            try await Subprocess.run(
                .path(try HostPlatform.bundledTool("xtool-zip")),
                arguments: ["compress", dir.path, dest.path],
                workingDirectory: FilePath(dir.deletingLastPathComponent()),
                output: .discarded,
            ).checkSuccess()
            #else
            try await Subprocess.run(
                .name("zip"),
                arguments: ["-yqru0", dest.path, dir.lastPathComponent],
                workingDirectory: FilePath(dir.deletingLastPathComponent()),
                output: .discarded,
            ).checkSuccess()

            #endif

            return dest
        },
        decompress: { ipa, directory, progress in
            progress(nil)

            #if os(Windows)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try await Subprocess.run(
                .path(try HostPlatform.bundledTool("xtool-zip")),
                arguments: ["extract", ipa.path, directory.path],
                output: .discarded,
            ).checkSuccess()
            #else
            try await Subprocess.run(
                .name("unzip"),
                arguments: ["-q", ipa.path, "-d", directory.path],
                output: .discarded,
            ).checkSuccess()
            #endif
        }
    )
}
