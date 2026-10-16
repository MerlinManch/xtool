#pragma once
#ifdef _WIN32
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <filesystem>
#include <initializer_list>
#include <stdexcept>
#include <string>

namespace xtool_windows {
class SymlinkError : public std::runtime_error {
    DWORD error;
public:
    SymlinkError(const std::filesystem::path& path, DWORD code)
        : std::runtime_error("Cannot create Windows symbolic links at '" + path.u8string() +
            "' (Windows error " + std::to_string(code) + ")." +
            (code == ERROR_PRIVILEGE_NOT_HELD
                ? " Enable Windows Developer Mode in Settings (search for 'Developer Mode'), "
                  "or run from an elevated PowerShell with symbolic-link privileges. "
                  "Xcode SDKs require real file and directory symbolic links."
                : " Check permissions and symbolic-link support on the destination volume.")),
          error(code) {}
    DWORD code() const noexcept { return error; }
};

inline std::wstring extendedPath(const std::filesystem::path& path) {
    auto name = std::filesystem::absolute(path).lexically_normal().native();
    if (name.rfind(L"\\\\?\\", 0) == 0) return name;
    if (name.rfind(L"\\\\", 0) == 0) return L"\\\\?\\UNC\\" + name.substr(2);
    return L"\\\\?\\" + name;
}

inline void requireSymbolicLinks(const std::filesystem::path& output) {
    std::filesystem::create_directories(output);
    std::wstring probe;
    bool claimed = false;
    for (unsigned int attempt = 0; attempt < 16; ++attempt) {
        probe = extendedPath(output / (L".xtool-symlink-check-" +
            std::to_wstring(GetCurrentProcessId()) + L"-" +
            std::to_wstring(GetTickCount64()) + L"-" + std::to_wstring(attempt)));
        if (CreateDirectoryW(probe.c_str(), nullptr)) { claimed = true; break; }
        const DWORD error = GetLastError();
        if (error != ERROR_ALREADY_EXISTS) throw SymlinkError(output, error);
    }
    if (!claimed) throw SymlinkError(output, ERROR_ALREADY_EXISTS);
    // Remove only our exclusive probe and its two links. Never traverse a link
    // or remove existing user files, including on a partially failed check.
    struct Probe {
        const std::wstring& name;
        ~Probe() {
            DeleteFileW((name + L"\\file-link").c_str());
            RemoveDirectoryW((name + L"\\directory-link").c_str());
            RemoveDirectoryW(name.c_str());
        }
    } cleanup{probe};
    for (DWORD directoryFlag : {DWORD(0), DWORD(SYMBOLIC_LINK_FLAG_DIRECTORY)}) {
        const auto name = probe + (directoryFlag ? L"\\directory-link" : L"\\file-link");
        const auto target = directoryFlag ? L"absent-directory" : L"absent-file";
        if (CreateSymbolicLinkW(name.c_str(), target,
            directoryFlag | DWORD(SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE))) continue;
        DWORD error = GetLastError();
        if (error == ERROR_INVALID_PARAMETER) {
            if (CreateSymbolicLinkW(name.c_str(), target, directoryFlag)) continue;
            error = GetLastError();
        }
        throw SymlinkError(output, error);
    }
}
}
#else
#include <filesystem>
namespace xtool_windows {
inline void requireSymbolicLinks(const std::filesystem::path&) {}
}
#endif
