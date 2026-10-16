// Native IPA archive handling with Unix executable and symlink attributes.
#include <archive.h>
#include <archive_entry.h>
#include "deferred_symlinks.hpp"
#include <array>
#include <clocale>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <string>
namespace fs = std::filesystem;
struct ReadFree { void operator()(archive* p) const { archive_read_free(p); } };
struct WriteFree { void operator()(archive* p) const { archive_write_free(p); } };
struct EntryFree { void operator()(archive_entry* p) const { archive_entry_free(p); } };
using Reader = std::unique_ptr<archive, ReadFree>;
using Writer = std::unique_ptr<archive, WriteFree>;

static void check(int status, archive* handle) {
    if (status < ARCHIVE_OK) {
        const auto* error = archive_error_string(handle);
        throw std::runtime_error(error ? error : "Archive operation failed");
    }
}
static bool executable(const fs::path& path) {
    std::ifstream input(path, std::ios::binary);
    std::array<unsigned char, 4> bytes{};
    input.read(reinterpret_cast<char*>(bytes.data()), bytes.size());
    if (input.gcount() < 2) return false;
    if (bytes[0] == '#' && bytes[1] == '!') return true;
    if (input.gcount() != 4) return false;
    const uint32_t magic = (uint32_t(bytes[0]) << 24) | (uint32_t(bytes[1]) << 16) |
                          (uint32_t(bytes[2]) << 8) | uint32_t(bytes[3]);
    return magic == 0xfeedface || magic == 0xcefaedfe || magic == 0xfeedfacf || magic == 0xcffaedfe ||
           magic == 0xcafebabe || magic == 0xbebafeca || magic == 0xcafebabf || magic == 0xbfbafeca;
}
static void compress(const fs::path& source, const fs::path& destination) {
    Reader disk(archive_read_disk_new());
    check(archive_read_disk_set_symlink_physical(disk.get()), disk.get());
#ifdef _WIN32
    check(archive_read_disk_open_w(disk.get(), source.c_str()), disk.get());
#else
    check(archive_read_disk_open(disk.get(), source.c_str()), disk.get());
#endif
    Writer zip(archive_write_new());
    check(archive_write_set_format_zip(zip.get()), zip.get());
    check(archive_write_set_options(zip.get(), "zip:compression=store"), zip.get());
    // Windows otherwise converts link payloads to its OEM code page, even
    // when archive entry names were supplied as UTF-8. IPA links must be UTF-8.
    check(archive_write_set_format_option(zip.get(), "zip", "hdrcharset", "UTF-8"), zip.get());
#ifdef _WIN32
    check(archive_write_open_filename_w(zip.get(), destination.c_str()), zip.get());
#else
    check(archive_write_open_filename(zip.get(), destination.c_str()), zip.get());
#endif
    std::unique_ptr<archive_entry, EntryFree> entry(archive_entry_new());
    std::array<char, 65536> buffer{};
    for (;;) {
        archive_entry_clear(entry.get());
        const auto status = archive_read_next_header2(disk.get(), entry.get());
        if (status == ARCHIVE_EOF) break;
        check(status, disk.get());
#ifdef _WIN32
        const fs::path fullPath(archive_entry_pathname_w(entry.get()));
#else
        const fs::path fullPath(archive_entry_pathname(entry.get()));
#endif
        const auto name = fullPath.lexically_relative(source.parent_path()).generic_u8string();
        archive_entry_set_pathname_utf8(entry.get(), name.c_str());
        const auto type = archive_entry_filetype(entry.get());
        if (type == AE_IFDIR) {
            archive_entry_set_perm(entry.get(), 0755);
            check(archive_read_disk_descend(disk.get()), disk.get());
        } else if (type == AE_IFREG) {
            // NTFS has no POSIX execute bit. Mach-O binaries must remain executable
            // after installd or AFC extracts the IPA on the device.
            archive_entry_set_perm(entry.get(), executable(fullPath) ? 0755 : 0644);
        } else if (type == AE_IFLNK) {
            archive_entry_set_perm(entry.get(), 0777);
        } else {
            throw std::runtime_error("Unsupported special file in app bundle");
        }
        check(archive_write_header(zip.get(), entry.get()), zip.get());
        if (type == AE_IFREG) {
            std::ifstream input(fullPath, std::ios::binary);
            if (!input) throw std::runtime_error("Cannot read app bundle file");
            while (input) {
                input.read(buffer.data(), buffer.size());
                const auto count = input.gcount();
                size_t position = 0;
                while (position < static_cast<size_t>(count)) {
                    const auto written = archive_write_data(zip.get(), buffer.data() + position,
                                                           static_cast<size_t>(count) - position);
                    if (written <= 0) throw std::runtime_error("Could not write IPA file data");
                    position += static_cast<size_t>(written);
                }
            }
            if (!input.eof()) throw std::runtime_error("Failed reading app bundle file");
        }
        check(archive_write_finish_entry(zip.get()), zip.get());
    }
    check(archive_write_close(zip.get()), zip.get());
}
static void extract(const fs::path& source, const fs::path& destination) {
    Reader zip(archive_read_new());
    check(archive_read_support_format_zip(zip.get()), zip.get());
    // IPA symlink payloads are UTF-8 even when their ASCII entry names do not
    // cause a ZIP language-encoding flag to be emitted.
    check(archive_read_set_format_option(zip.get(), "zip", "hdrcharset", "UTF-8"), zip.get());
#ifdef _WIN32
    check(archive_read_open_filename_w(zip.get(), source.c_str(), 65536), zip.get());
#else
    check(archive_read_open_filename(zip.get(), source.c_str(), 65536), zip.get());
#endif
    Writer disk(archive_write_disk_new());
    check(archive_write_disk_set_options(disk.get(), ARCHIVE_EXTRACT_TIME |
        ARCHIVE_EXTRACT_SECURE_SYMLINKS | ARCHIVE_EXTRACT_SECURE_NODOTDOT |
        ARCHIVE_EXTRACT_SECURE_NOABSOLUTEPATHS), disk.get());
    fs::create_directories(destination);
    fs::current_path(destination);
    DeferredSymlinks symlinks;
    archive_entry* entry = nullptr;
    for (;;) {
        const auto status = archive_read_next_header(zip.get(), &entry);
        if (status == ARCHIVE_EOF) break;
        check(status, zip.get());
        if (!symlinks.defer(entry)) {
            check(archive_read_extract2(zip.get(), entry, disk.get()), zip.get());
        }
    }
    symlinks.finish(disk.get());
    check(archive_write_close(disk.get()), disk.get());
}
#ifdef _WIN32
int wmain(int argc, wchar_t** argv) {
#else
int main(int argc, char** argv) {
#endif
    try {
#ifdef _WIN32
        std::setlocale(LC_ALL, ".UTF8");
#else
        std::setlocale(LC_ALL, "");
#endif
        if (argc != 4) throw std::runtime_error("Usage: xtool-zip <compress|extract> <source> <destination>");
        const auto source = fs::absolute(argv[2]);
        const auto destination = fs::absolute(argv[3]);
        const auto command = fs::path(argv[1]).string();
        if (command == "compress") compress(source, destination);
        else if (command == "extract") extract(source, destination);
        else throw std::runtime_error("Unknown archive command");
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "xtool-zip: " << error.what() << '\n';
        return 1;
    }
}
