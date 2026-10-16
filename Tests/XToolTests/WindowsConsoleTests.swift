#if os(Windows)
import Foundation
import Testing
import WinSDK
@testable import XToolSupport

@Suite(.serialized)
struct WindowsConsoleTests {
    @Test(.timeLimit(.minutes(1))) func unicodePasswordInputRestoresConsoleEcho() async throws {
        let allocated = AllocConsole()
        defer { if allocated { _ = FreeConsole() } }
        let previous = GetStdHandle(STD_INPUT_HANDLE)
        let handle = "CONIN$".withCString(encodedAs: UTF16.self) {
            CreateFileW($0, DWORD(GENERIC_READ) | DWORD(GENERIC_WRITE),
                        DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE), nil, DWORD(OPEN_EXISTING), 0, nil)
        }
        let input = try #require(handle)
        #expect(input != INVALID_HANDLE_VALUE)
        guard input != INVALID_HANDLE_VALUE else { return }
        defer { _ = CloseHandle(input) }
        try #require(SetStdHandle(STD_INPUT_HANDLE, input))
        defer { _ = SetStdHandle(STD_INPUT_HANDLE, previous) }
        var mode: DWORD = 0
        try #require(GetConsoleMode(input, &mode))
        let expectedMode = mode | DWORD(ENABLE_ECHO_INPUT | ENABLE_LINE_INPUT | ENABLE_PROCESSED_INPUT)
        try #require(SetConsoleMode(input, expectedMode))
        defer { _ = SetConsoleMode(input, mode) }
        _ = FlushConsoleInputBuffer(input)
        let password = "Windows ü 🔐"
        var records = Array((password + "\r").utf16).map { unit in
            var record = INPUT_RECORD()
            record.EventType = WORD(KEY_EVENT)
            record.Event.KeyEvent.bKeyDown = true
            record.Event.KeyEvent.wRepeatCount = 1
            record.Event.KeyEvent.uChar.UnicodeChar = unit
            if unit == 13 { record.Event.KeyEvent.wVirtualKeyCode = WORD(VK_RETURN) }
            return record
        }
        let recordCount = DWORD(records.count)
        var written: DWORD = 0
        try #require(WriteConsoleInputW(input, &records, recordCount, &written))
        #expect(written == DWORD(records.count))
        let result = try await Console.getPassword("")
        #expect(result == password)
        var restored: DWORD = 0
        try #require(GetConsoleMode(input, &restored))
        #expect(restored == expectedMode)
    }
}
#endif
