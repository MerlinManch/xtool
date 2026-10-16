#if os(Windows)
import Foundation
import XUtils

extension SDKBuilder {
    /// The LLVM distribution and the macro server must be built for the Windows
    /// host. Never install the similarly named Linux release executables here.
    private func windowsResource(_ variable: String, defaultName: String) throws -> URL {
        if let value = ProcessInfo.processInfo.environment[variable] {
            return URL(fileURLWithPath: value)
        }
        guard let executable = Bundle.main.executableURL else {
            throw Console.Error("Could not locate xtool executable")
        }
        return executable.deletingLastPathComponent().appendingPathComponent(defaultName)
    }

    func installWindowsToolset(in output: URL) throws {
        print("[Installing native Windows toolset]")
        let source = try windowsResource("XTOOL_WINDOWS_TOOLSET", defaultName: "windows-toolset")
        let directory = output.appendingPathComponent("toolset")
        for name in ["ld64.lld.exe", "llvm-libtool-darwin.exe", "dsymutil.exe"] {
            try requireWindowsExecutable(source.appending(path: "bin/\(name)"))
        }
        do {
            try FileManager.default.copyWindowsTree(at: source, to: directory)
        } catch {
            throw Console.Error("Could not copy toolset '\(source.path)' to '\(directory.path)': \(error)")
        }
        let bin = directory.appendingPathComponent("bin")
        let orig = bin.appendingPathComponent("orig")
        try FileManager.default.createDirectory(at: orig, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: bin.appendingPathComponent("ld64.lld.exe"),
                                         to: orig.appendingPathComponent("ld64.lld.exe"))
        for file in try FileManager.default.contentsOfDirectory(at: bin, includingPropertiesForKeys: nil)
            where file.pathExtension.lowercased() == "dll" {
            try FileManager.default.copyItem(at: file, to: orig.appendingPathComponent(file.lastPathComponent))
        }
        try FileManager.default.copyItem(at: bin.appendingPathComponent("llvm-libtool-darwin.exe"),
                                         to: bin.appendingPathComponent("llvm-lib.exe"))
        try FileManager.default.copyItem(at: URL(fileURLWithPath: HostPlatform.bundledTool("xtool-linker").string),
                                         to: bin.appendingPathComponent("ld64.lld.exe"))
        try FileManager.default.copyItem(at: URL(fileURLWithPath: HostPlatform.bundledTool("xtool-codesign").string),
                                         to: bin.appendingPathComponent("xtool-codesign.exe"))
    }

    func installWindowsMacros(in output: URL) throws {
        print("[Installing native Windows macro server]")
        let source = try windowsResource("XTOOL_WINDOWS_MACROS", defaultName: "windows-macros")
        let executable = source.appendingPathComponent("OpenAppleMacrosServer.exe")
        try requireWindowsExecutable(executable)
        // Keep companion Swift runtime DLLs beside the macro server.
        for file in try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
            let destination = output.appendingPathComponent(file.lastPathComponent)
            do {
                try FileManager.default.copyWindowsTree(at: file, to: destination)
            } catch {
                throw Console.Error("Could not copy macro resource '\(file.path)' to '\(destination.path)': \(error)")
            }
        }
    }

    func installWindowsMacroRuntime(from output: URL, in bin: URL) throws {
        // Windows searches beside the path used to start an executable. An
        // executable symlink does not redirect the DLL search to its target.
        for file in try FileManager.default.contentsOfDirectory(at: output, includingPropertiesForKeys: nil)
            where file.pathExtension.lowercased() == "dll" {
            try FileManager.default.copyWindowsTree(at: file, to: bin.appendingPathComponent(file.lastPathComponent))
        }
    }

    private func requireWindowsExecutable(_ url: URL) throws {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw Console.Error("Missing native Windows tool '\(url.path)'. See Windows/README.md.")
        }
        defer { try? handle.close() }
        guard let dosHeader = try handle.read(upToCount: 64), dosHeader.count == 64,
              dosHeader.prefix(2) == Data([0x4d, 0x5a]) else {
            throw Console.Error("Expected a native PE executable at '\(url.path)'.")
        }
        let offset = dosHeader[60..<64].enumerated().reduce(UInt64(0)) { value, byte in
            value | (UInt64(byte.element) << (byte.offset * 8))
        }
        try handle.seek(toOffset: offset)
        guard let header = try handle.read(upToCount: 6), header.count == 6,
              header.prefix(4) == Data([0x50, 0x45, 0, 0]) else {
            throw Console.Error("Invalid PE header in '\(url.path)'.")
        }
        let machine = UInt16(header[4]) | (UInt16(header[5]) << 8)
        let expected: UInt16 = arch == .aarch64 ? 0xaa64 : 0x8664
        guard machine == expected else {
            throw Console.Error("Native tool '\(url.path)' does not match host architecture '\(arch.rawValue)'.")
        }
    }
}
#endif
