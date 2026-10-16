import Foundation
import XKit
import XUtils

#if os(Windows)
import WinSDK
#else
import NIOPosix
import NIOCore
#endif

enum Console {
    #if !os(Windows)
    private static func withStdio<T>(
        _ body: (
            _ stdin: NIOAsyncChannelInboundStream<ByteBuffer>,
            _ stdout: NIOAsyncChannelOutboundWriter<ByteBuffer>
        ) async throws -> T
    ) async throws -> T {
        try await NIOPipeBootstrap(group: .singletonMultiThreadedEventLoopGroup)
            .takingOwnershipOfDescriptors(
                input: FileDescriptor.standardInput.duplicate().rawValue,
                output: FileDescriptor.standardOutput.duplicate().rawValue
            )
            .flatMapThrowing { try NIOAsyncChannel(wrappingChannelSynchronously: $0) }
            .get()
            .executeThenClose { try await body($0, $1) }
    }

    #endif

    static func prompt(_ message: String) async throws -> String {
        #if os(Windows)
        // NIOPipeBootstrap uses POSIX descriptors and is unavailable on Windows.
        // Read one line without consuming the next prompt from redirected input.
        try FileHandle.standardOutput.write(contentsOf: Data(message.utf8))
        let console = GetStdHandle(STD_INPUT_HANDLE)
        var mode: DWORD = 0
        if GetConsoleMode(console, &mode) != 0 {
            return try readWindowsConsoleLine()
        }
        return try readRedirectedLine()
        #else
        try await withStdio { stdin, stdout in
            try await stdout.write(ByteBuffer(bytes: message.utf8))

            fflush(stdoutSafe)

            var data = Data()
            for try await chunk in stdin {
                let view = chunk.readableBytesView
                if let endIndex = view.firstIndex(of: UInt8(ascii: "\n")) {
                    data += view[..<endIndex]
                    break
                } else {
                    data += view
                }
            }
            let str = String(decoding: data, as: UTF8.self)
            return str.hasSuffix("\r") ? String(str.dropLast()) : str
        }
        #endif
    }

    #if os(Windows)
    private static func readWindowsConsoleLine() throws -> String {
        let console = GetStdHandle(STD_INPUT_HANDLE)
        var units: [UInt16] = []
        while true {
            if HostPlatform.interrupted { throw CancellationError() }
            var buffer = [UInt16](repeating: 0, count: 1024)
            var count: DWORD = 0
            guard ReadConsoleW(console, &buffer, 1024, &count, nil) != 0 else {
                if HostPlatform.interrupted { throw CancellationError() }
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(GetLastError()))
            }
            if count == 0 { break }
            let chunk = buffer.prefix(Int(count))
            if let newline = chunk.firstIndex(of: 10) {
                units.append(contentsOf: chunk[..<newline])
                break
            }
            units.append(contentsOf: chunk)
        }
        if units.last == 13 { units.removeLast() }
        return String(decoding: units, as: UTF16.self)
    }

    private static func readRedirectedLine() throws -> String {
        var data = Data()
        while let byte = try FileHandle.standardInput.read(upToCount: 1), !byte.isEmpty {
            if byte[0] == 10 { break }
            data.append(byte)
        }
        if data.last == 13 { data.removeLast() }
        return String(decoding: data, as: UTF8.self)
    }
    #endif

    static func promptRequired(_ message: String, existing: String?) async throws -> String {
        let value: String
        if let existing {
            value = existing
        } else {
            value = try await Console.prompt(message)
        }
        guard !value.isEmpty else {
            throw Console.Error("Input cannot be empty.")
        }
        return value
    }

    static func getPassword(_ message: String) async throws -> String {
        if !message.isEmpty {
            print(message, terminator: "")
        }
        fflush(stdoutSafe)
        let password = try await withoutEcho { try await prompt("") }
        print()
        return password
    }

    private static func withoutEcho<T>(_ action: () async throws -> T) async throws -> T {
        #if os(Windows)
        let console = GetStdHandle(STD_INPUT_HANDLE)
        var oldMode: DWORD = 0
        // Redirected input has no console mode; no echo is generated there.
        let isConsole = GetConsoleMode(console, &oldMode) != 0
        if isConsole {
            guard SetConsoleMode(console, oldMode & ~DWORD(ENABLE_ECHO_INPUT)) != 0 else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(GetLastError()))
            }
        }
        defer { if isConsole { _ = SetConsoleMode(console, oldMode) } }
        return try await action()
        #else
        var origAttr = termios()
        tcgetattr(STDIN_FILENO, &origAttr)

        var newAttr = origAttr
        newAttr.c_lflag = newAttr.c_lflag & ~tcflag_t(ECHO)
        tcsetattr(STDIN_FILENO, TCSANOW, &newAttr)
        defer { tcsetattr(STDIN_FILENO, TCSANOW, &origAttr) }

        return try await action()
        #endif
    }

    static func chooseNumber(in range: Range<Int>) async throws -> Int {
        let message = "Choice (\(range.lowerBound)-\(range.upperBound - 1)): "
        while true {
            if let choice = try await Int(prompt(message)), range.contains(choice) {
                return choice
            }
        }
    }

    static func choose<T>(
        from elements: [T],
        onNoElement: () throws -> T,
        multiPrompt: @autoclosure () -> String,
        formatter: (T) throws -> String
    ) async throws -> T {
        switch elements.count {
        case 0:
            return try onNoElement()
        case 1:
            return elements[0]
        default:
            print(multiPrompt())
            try elements.enumerated().forEach { index, element in
                try print("\(index): \(formatter(element))")
            }
            let choice = try await chooseNumber(in: elements.indices)
            return elements[choice]
        }
    }

    private static let yesSet: Set<String> = ["yes", "y"]
    private static let noSet: Set<String> = ["no", "n"]

    static func confirm(_ message: String) async throws -> Bool {
        while true {
            let resp = try await prompt("\(message) (yes/no): ").lowercased()
            if yesSet.contains(resp) {
                return true
            } else if noSet.contains(resp) {
                return false
            }
        }
    }

    struct Error: Swift.Error, CustomStringConvertible {
        let description: String
        init(_ description: String) {
            self.description = description
        }
    }
}
