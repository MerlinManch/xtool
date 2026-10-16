#pragma once
#include <archive_entry.h>
#ifdef _WIN32
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <filesystem>
#include <set>
#include <stdexcept>
#include <string>

// Xcode contains distinct case-only paths (including hardlinked manpages).
// Prepare each directory before libarchive creates its children. Do not rely
// on inheritance: Windows tools can create case-insensitive child directories.
class CaseSensitiveDirectories {
    std::set<std::wstring> prepared;
    static std::wstring extended(const std::filesystem::path& path) {
        auto name = std::filesystem::absolute(path).lexically_normal().native();
        if (name.rfind(L"\\\\?\\", 0) == 0) return name;
        if (name.rfind(L"\\\\", 0) == 0) return L"\\\\?\\UNC\\" + name.substr(2);
        return L"\\\\?\\" + name;
    }
    [[noreturn]] static void fail(const std::filesystem::path& path, DWORD error) {
        throw std::runtime_error("Could not prepare case-sensitive Xcode directory '" +
            path.u8string() + "' (Windows error " + std::to_string(error) +
            "). A local NTFS volume with per-directory case sensitivity is required. "
            "Check directory permissions; enabling the flag may require an elevated terminal.");
    }
public:
    void prepare(archive_entry* entry) {
        const auto raw = archive_entry_pathname_w(entry);
        if (!raw) throw std::runtime_error("Missing archive entry pathname");
        const std::filesystem::path path(raw);
        if (path.has_root_path()) throw std::runtime_error("Absolute archive path rejected");
        for (const auto& part : path) {
            if (part == L"..") throw std::runtime_error("Parent traversal in archive path rejected");
        }
        const auto parent = archive_entry_filetype(entry) == AE_IFDIR ? path : path.parent_path();
        std::filesystem::path current;
        for (const auto& part : parent) {
            if (part.empty() || part == L".") continue;
            current /= part;
            const auto name = extended(current);
            if (prepared.count(name)) continue;
            DWORD attributes = GetFileAttributesW(name.c_str());
            if (attributes == INVALID_FILE_ATTRIBUTES) {
                const auto error = GetLastError();
                if (error != ERROR_FILE_NOT_FOUND && error != ERROR_PATH_NOT_FOUND) fail(current, error);
                if (!CreateDirectoryW(name.c_str(), nullptr) && GetLastError() != ERROR_ALREADY_EXISTS) {
                    fail(current, GetLastError());
                }
                attributes = GetFileAttributesW(name.c_str());
            }
            if (attributes == INVALID_FILE_ATTRIBUTES) fail(current, GetLastError());
            if (!(attributes & FILE_ATTRIBUTE_DIRECTORY) || (attributes & FILE_ATTRIBUTE_REPARSE_POINT)) {
                throw std::runtime_error("Archive parent is not a plain directory: " + current.u8string());
            }
            const HANDLE directory = CreateFileW(name.c_str(), FILE_READ_ATTRIBUTES | FILE_WRITE_ATTRIBUTES,
                FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr, OPEN_EXISTING,
                FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, nullptr);
            if (directory == INVALID_HANDLE_VALUE) fail(current, GetLastError());
            // FILE_CASE_SENSITIVE_INFORMATION is one ULONG; information class
            // 23 is FileCaseSensitiveInfo, flag 1 is FILE_CS_FLAG_CASE_SENSITIVE_DIR.
            DWORD flags = 0;
            const auto information = static_cast<FILE_INFO_BY_HANDLE_CLASS>(23);
            BOOL success = GetFileInformationByHandleEx(directory, information, &flags, sizeof(flags));
            if (success && !(flags & 1)) {
                flags |= 1;
                success = SetFileInformationByHandle(directory, information, &flags, sizeof(flags));
            }
            const DWORD error = success ? ERROR_SUCCESS : GetLastError();
            CloseHandle(directory);
            if (!success) fail(current, error);
            prepared.insert(name);
        }
    }
};
#else
class CaseSensitiveDirectories {
public:
    void prepare(archive_entry*) {}
};
#endif
