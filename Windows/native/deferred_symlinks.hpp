#pragma once
#include <archive.h>
#include <archive_entry.h>
#include <filesystem>
#include <memory>
#include <stdexcept>
#include <vector>

// CPIO/Unix ZIP do not record whether a symlink targets a file or directory.
// Windows requires this distinction at creation time. Wait for target extraction,
// including forward references and chains, then supply the correct type to the
// libarchive disk writer while retaining its path-traversal protection.
class DeferredSymlinks {
#ifdef _WIN32
    struct FreeEntry { void operator()(archive_entry* entry) const { archive_entry_free(entry); } };
    std::vector<std::unique_ptr<archive_entry, FreeEntry>> entries;
    static void write(archive* disk, archive_entry* entry) {
        if (archive_write_header(disk, entry) < ARCHIVE_OK ||
            archive_write_finish_entry(disk) < ARCHIVE_OK) {
            const char* error = archive_error_string(disk);
            const std::filesystem::path name(archive_entry_pathname_w(entry));
            const std::filesystem::path target(archive_entry_symlink_w(entry));
            throw std::runtime_error("Could not restore symbolic link '" + name.u8string() +
                "' -> '" + target.u8string() + "' (archive error " +
                std::to_string(archive_errno(disk)) + "): " +
                (error ? error : "Unknown archive error"));
        }
    }
#endif
public:
    bool defer(archive_entry* entry) {
#ifdef _WIN32
        if (archive_entry_symlink_w(entry)) {
            auto copy = archive_entry_clone(entry);
            if (!copy) throw std::bad_alloc();
            entries.emplace_back(copy);
            return true;
        }
#else
        (void)entry;
#endif
        return false;
    }
    void finish(archive* disk) {
#ifdef _WIN32
        while (!entries.empty()) {
            const auto previous = entries.size();
            for (auto it = entries.begin(); it != entries.end();) {
                const std::filesystem::path name(archive_entry_pathname_w(it->get()));
                const std::filesystem::path target(archive_entry_symlink_w(it->get()));
                std::error_code error;
                const auto status = std::filesystem::status(name.parent_path() / target, error);
                if (error || !std::filesystem::exists(status)) { ++it; continue; }
                archive_entry_set_symlink_type(it->get(), std::filesystem::is_directory(status)
                    ? AE_SYMLINK_TYPE_DIRECTORY : AE_SYMLINK_TYPE_FILE);
                write(disk, it->get());
                it = entries.erase(it);
            }
            if (entries.size() == previous) {
                // Preserve dangling links/cycles using any archive type hint.
                for (const auto& entry : entries) write(disk, entry.get());
                entries.clear();
            }
        }
#else
        (void)disk;
#endif
    }
};
