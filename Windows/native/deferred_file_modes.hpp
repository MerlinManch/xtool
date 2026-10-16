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
#include <vector>

// CPIO hardlink entries may carry data at either end of a link group. Keep
// files writable until every payload is restored, then project the archived
// owner-write bit onto Windows' read-only attribute in archive order.
class DeferredFileModes {
    struct Entry { std::filesystem::path name; bool readOnly; };
    std::vector<Entry> entries;
    static std::wstring extended(const std::filesystem::path& path) {
        auto name = std::filesystem::absolute(path).lexically_normal().native();
        if (name.rfind(L"\\\\?\\", 0) == 0) return name;
        if (name.rfind(L"\\\\", 0) == 0) return L"\\\\?\\UNC\\" + name.substr(2);
        return L"\\\\?\\" + name;
    }
    [[noreturn]] static void fail(const std::filesystem::path& path, DWORD error) {
        throw std::runtime_error("Could not restore Windows file mode for '" +
            path.u8string() + "' (Windows error " + std::to_string(error) + ")");
    }
public:
    void prepare(archive_entry* entry) {
        const bool hardlink = archive_entry_hardlink_w(entry) != nullptr;
        if (archive_entry_filetype(entry) != AE_IFREG && !hardlink) return;
        const auto name = archive_entry_pathname_w(entry);
        if (!name) throw std::runtime_error("Missing archive file mode pathname");
        const auto permissions = archive_entry_perm(entry);
        // Like libarchive, a data-less hardlink does not override the target's
        // metadata; a hardlink carrying a later payload is authoritative.
        if (!hardlink || archive_entry_size(entry) > 0) {
            entries.push_back({std::filesystem::path(name), (permissions & 0200) == 0});
        }
        archive_entry_set_perm(entry, static_cast<decltype(archive_entry_perm(entry))>(permissions | 0200));
    }
    void finish() {
        std::set<std::wstring> checkedParents;
        for (const auto& entry : entries) {
            std::filesystem::path parent;
            for (const auto& part : entry.name.parent_path()) {
                if (part.empty() || part == L".") continue;
                parent /= part;
                const auto name = extended(parent);
                if (!checkedParents.insert(name).second) continue;
                const DWORD attrs = GetFileAttributesW(name.c_str());
                if (attrs == INVALID_FILE_ATTRIBUTES) fail(parent, GetLastError());
                if (!(attrs & FILE_ATTRIBUTE_DIRECTORY) || (attrs & FILE_ATTRIBUTE_REPARSE_POINT)) {
                    throw std::runtime_error("Archive file mode has a non-directory or symbolic-link parent");
                }
            }
            const auto name = extended(entry.name);
            const DWORD attrs = GetFileAttributesW(name.c_str());
            if (attrs == INVALID_FILE_ATTRIBUTES) fail(entry.name, GetLastError());
            // A later archive entry may replace a regular file with a link or
            // directory. Do not apply the superseded regular-file mode to it.
            if (attrs & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)) continue;
            constexpr DWORD settable = FILE_ATTRIBUTE_ARCHIVE | FILE_ATTRIBUTE_HIDDEN |
                FILE_ATTRIBUTE_NORMAL | FILE_ATTRIBUTE_NOT_CONTENT_INDEXED | FILE_ATTRIBUTE_OFFLINE |
                FILE_ATTRIBUTE_READONLY | FILE_ATTRIBUTE_SYSTEM | FILE_ATTRIBUTE_TEMPORARY;
            DWORD flags = attrs & settable;
            if (entry.readOnly) flags |= FILE_ATTRIBUTE_READONLY;
            else flags &= ~FILE_ATTRIBUTE_READONLY;
            if (flags & ~FILE_ATTRIBUTE_NORMAL) flags &= ~FILE_ATTRIBUTE_NORMAL;
            if (!flags) flags = FILE_ATTRIBUTE_NORMAL;
            if (!SetFileAttributesW(name.c_str(), flags)) fail(entry.name, GetLastError());
        }
    }
};
#else
class DeferredFileModes {
public:
    void prepare(archive_entry*) {}
    void finish() {}
};
#endif
