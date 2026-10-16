// Native counterpart of SDKBuilder's POSIX ld64.lld trampoline.
#include <filesystem>
#include <iostream>
#include <string>
#include <vector>
#include <algorithm>
#include <fstream>
#include <iterator>
#include <cstdint>
#include <stdexcept>
#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <process.h>
using String = std::wstring;
#define XTL_TEXT(value) L##value
#define EXECUTABLE_SUFFIX L".exe"
#else
#include <unistd.h>
using String = std::string;
#define XTL_TEXT(value) value
#define EXECUTABLE_SUFFIX ""
#endif
namespace fs = std::filesystem;


static void appendUTF8(std::string& text, uint32_t value) {
    if (value < 0x80) text += static_cast<char>(value);
    else if (value < 0x800) {
        text += static_cast<char>(0xc0 | (value >> 6));
        text += static_cast<char>(0x80 | (value & 63));
    } else if (value < 0x10000) {
        text += static_cast<char>(0xe0 | (value >> 12));
        text += static_cast<char>(0x80 | ((value >> 6) & 63));
        text += static_cast<char>(0x80 | (value & 63));
    } else {
        text += static_cast<char>(0xf0 | (value >> 18));
        text += static_cast<char>(0x80 | ((value >> 12) & 63));
        text += static_cast<char>(0x80 | ((value >> 6) & 63));
        text += static_cast<char>(0x80 | (value & 63));
    }
}
static String responseText(std::string data) {
    if (data.size() >= 2 && static_cast<unsigned char>(data[0]) == 0xff &&
        static_cast<unsigned char>(data[1]) == 0xfe) {
        if (data.size() % 2) throw std::runtime_error("Invalid UTF-16 response file");
        std::string text;
        auto unit = [&](size_t i) -> uint32_t {
            return static_cast<unsigned char>(data[i]) | (uint32_t(static_cast<unsigned char>(data[i + 1])) << 8);
        };
        for (size_t i = 2; i < data.size(); i += 2) {
            uint32_t value = unit(i);
            if (value >= 0xd800 && value <= 0xdbff) {
                i += 2;
                if (i + 1 >= data.size() || unit(i) < 0xdc00 || unit(i) > 0xdfff)
                    throw std::runtime_error("Invalid UTF-16 surrogate");
                value = 0x10000 + ((value - 0xd800) << 10) + unit(i) - 0xdc00;
            } else if (value >= 0xdc00 && value <= 0xdfff) {
                throw std::runtime_error("Invalid UTF-16 surrogate");
            }
            appendUTF8(text, value);
        }
        data = std::move(text);
    } else if (data.compare(0, 3, "\xef\xbb\xbf") == 0) data.erase(0, 3);
#ifdef _WIN32
    const int size = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, data.data(), static_cast<int>(data.size()), nullptr, 0);
    if (!size && !data.empty()) throw std::runtime_error("Invalid UTF-8 response file");
    String result(static_cast<size_t>(size), L'\0');
    MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, data.data(), static_cast<int>(data.size()), result.data(), size);
    return result;
#else
    return data;
#endif
}
static std::vector<String> splitResponse(const String& text) {
    std::vector<String> args;
    size_t position = 0;
    auto space = [](auto c) { return c == ' ' || c == '\t' || c == '\r' || c == '\n'; };
    while (position < text.size()) {
        while (position < text.size() && space(text[position])) ++position;
        if (position == text.size()) break;
        String arg;
        bool quoted = false;
        while (position < text.size() && (quoted || !space(text[position]))) {
            size_t slashes = 0;
            while (position < text.size() && text[position] == '\\') { ++slashes; ++position; }
            if (position < text.size() && text[position] == '"') {
                arg.append(slashes / 2, '\\');
                if (slashes % 2) arg += '"';
                else if (quoted && position + 1 < text.size() && text[position + 1] == '"') {
                    arg += '"'; ++position;
                } else quoted = !quoted;
                ++position;
            } else {
                arg.append(slashes, '\\');
                if (position < text.size() && !quoted && space(text[position])) break;
                if (position < text.size()) arg += text[position++];
            }
        }
        if (quoted) throw std::runtime_error("Unterminated quote in response file");
        args.push_back(std::move(arg));
    }
    return args;
}
static std::vector<String> expandResponse(const std::vector<String>& args, unsigned depth = 0) {
    if (depth > 16) throw std::runtime_error("Response files nested too deeply");
    std::vector<String> expanded;
    for (const auto& arg : args) {
        if (arg.size() > 1 && arg[0] == '@') {
            std::ifstream file(fs::path(arg.substr(1)), std::ios::binary);
            if (file) {
                auto bytes = std::string(std::istreambuf_iterator<char>(file), std::istreambuf_iterator<char>());
                auto values = expandResponse(splitResponse(responseText(std::move(bytes))), depth + 1);
                expanded.insert(expanded.end(), values.begin(), values.end());
                continue;
            }
        }
        expanded.push_back(arg);
    }
    return expanded;
}

#ifdef _WIN32
// CreateProcess receives a single command line. Quote every argument using the
// MSVC CRT grammar; _wspawnv joins arguments without preserving their boundaries.
static String quoteArgument(const String& argument) {
    String result = L"\"";
    size_t slashes = 0;
    for (wchar_t character : argument) {
        if (character == L'\\') { ++slashes; continue; }
        if (character == L'"') {
            result.append(slashes * 2 + 1, L'\\');
        } else {
            result.append(slashes, L'\\');
        }
        slashes = 0;
        result += character;
    }
    result.append(slashes * 2, L'\\');
    result += L'"';
    return result;
}
#endif

static int run(const fs::path& executable, const std::vector<String>& args) {
    auto name = executable.native();
#ifdef _WIN32
    String commandLine = quoteArgument(name);
    for (const auto& arg : args) commandLine += L" " + quoteArgument(arg);
    STARTUPINFOW startup{};
    startup.cb = sizeof(startup);
    PROCESS_INFORMATION process{};
    if (!CreateProcessW(name.c_str(), commandLine.data(), nullptr, nullptr, TRUE,
                        0, nullptr, nullptr, &startup, &process)) return 127;
    CloseHandle(process.hThread);
    DWORD code = 127;
    if (WaitForSingleObject(process.hProcess, INFINITE) == WAIT_OBJECT_0) {
        if (!GetExitCodeProcess(process.hProcess, &code)) code = 127;
    }
    CloseHandle(process.hProcess);
    return static_cast<int>(code);
#else
    std::vector<const String::value_type*> argv = {name.c_str()};
    for (const auto& arg : args) argv.push_back(arg.c_str());
    argv.push_back(nullptr);
    execv(name.c_str(), const_cast<char* const*>(argv.data()));
    return 127;
#endif
}

#ifdef _WIN32
int wmain(int argc, wchar_t** argv) {
#else
int main(int argc, char** argv) {
#endif
    try {
        const fs::path directory = fs::absolute(argv[0]).parent_path();
        std::vector<String> args(argv + 1, argv + argc);
        // Keep all ordinary invocations byte-for-byte, including response files.
        const auto expanded = expandResponse(args);
        const bool relocatable = std::find(expanded.begin(), expanded.end(), XTL_TEXT("-r")) != expanded.end();
        if (!relocatable) {
            return run(directory / "orig" / XTL_TEXT("ld64.lld") EXECUTABLE_SUFFIX, args);
        }
        auto value = [&](const String& option) -> String {
            auto it = std::find(expanded.begin(), expanded.end(), option);
            if (it == expanded.end() || ++it == expanded.end() || it->empty()) {
                throw std::runtime_error("Missing linker argument value");
            }
            return *it;
        };
        std::vector<String> librarian = {
            XTL_TEXT("-static"), XTL_TEXT("-filelist"), value(XTL_TEXT("-filelist")),
            XTL_TEXT("-dependency_info"), value(XTL_TEXT("-dependency_info")),
            XTL_TEXT("-o"), value(XTL_TEXT("-o"))
        };
        return run(directory / XTL_TEXT("llvm-lib") EXECUTABLE_SUFFIX, librarian);
    } catch (const std::exception& error) {
        std::cerr << "xtool linker: " << error.what() << '\n';
        return 2;
    }
}
