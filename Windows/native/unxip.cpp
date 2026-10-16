// Streaming XAR -> PBZX/XZ -> CPIO extraction, using native libarchive/liblzma.
// Payload memory is bounded by two PBZX chunks; directory/link/mode metadata is retained separately.
#include <archive.h>
#include <archive_entry.h>
#include "deferred_symlinks.hpp"
#include "case_sensitive_directories.hpp"
#include "deferred_file_modes.hpp"
#include <lzma.h>
#include <array>
#include <cerrno>
#include <clocale>
#include <cstdint>
#include <cstring>
#include <filesystem>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

namespace fs = std::filesystem;
struct ReadDeleter { void operator()(archive* p) const { archive_read_free(p); } };
struct DiskDeleter { void operator()(archive* p) const { archive_write_free(p); } };
using Reader = std::unique_ptr<archive, ReadDeleter>;

static void check(int status, archive* reader) {
    if (status < ARCHIVE_OK) {
        const char* message = archive_error_string(reader);
        throw std::runtime_error(message ? message : "Archive operation failed");
    }
}

class PBZXReader {
    archive* xar;
    uint64_t chunkSize;
    bool finished = false;
    std::vector<uint8_t> compressed;
    std::vector<uint8_t> decoded;
    static constexpr uint64_t maxChunkSize = 64 * 1024 * 1024;

    void readExact(void* buffer, size_t count) {
        auto bytes = static_cast<uint8_t*>(buffer);
        while (count) {
            const auto size = archive_read_data(xar, bytes, count);
            if (size <= 0) throw std::runtime_error("Truncated PBZX stream");
            bytes += size;
            count -= static_cast<size_t>(size);
        }
    }
    uint64_t readUInt64() {
        std::array<uint8_t, 8> bytes{};
        readExact(bytes.data(), bytes.size());
        uint64_t value = 0;
        for (auto byte : bytes) value = (value << 8) | byte;
        return value;
    }
public:
    explicit PBZXReader(archive* source) : xar(source) {
        std::array<char, 4> magic{};
        readExact(magic.data(), magic.size());
        if (memcmp(magic.data(), "pbzx", 4)) throw std::runtime_error("Invalid PBZX magic");
        chunkSize = readUInt64();
        if (!chunkSize || chunkSize > maxChunkSize) throw std::runtime_error("Invalid PBZX chunk size");
    }
    la_ssize_t next(archive* cpio, const void** buffer) noexcept {
        try {
            if (finished) return 0;
            const uint64_t size = readUInt64();
            const uint64_t packedSize = readUInt64();
            if (size > chunkSize || packedSize > maxChunkSize || !packedSize) {
                throw std::runtime_error("Invalid PBZX block length");
            }
            finished = size < chunkSize;
            compressed.resize(static_cast<size_t>(packedSize));
            readExact(compressed.data(), compressed.size());
            if (packedSize == chunkSize) {
                if (size != packedSize) throw std::runtime_error("Invalid raw PBZX block length");
                *buffer = compressed.data();
                return static_cast<la_ssize_t>(compressed.size());
            }
            decoded.resize(static_cast<size_t>(size));
            size_t inputPosition = 0, outputPosition = 0;
            uint64_t memoryLimit = 512 * 1024 * 1024;
            const auto status = lzma_stream_buffer_decode(
                &memoryLimit, 0, nullptr, compressed.data(), &inputPosition, compressed.size(),
                decoded.data(), &outputPosition, decoded.size()
            );
            if (status != LZMA_OK || inputPosition != compressed.size() || outputPosition != decoded.size()) {
                throw std::runtime_error("Invalid XZ block in PBZX stream");
            }
            *buffer = decoded.data();
            return static_cast<la_ssize_t>(decoded.size());
        } catch (const std::exception& error) {
            archive_set_error(cpio, EINVAL, "%s", error.what());
            return -1;
        }
    }
    // Consume any bytes after the CPIO trailer so truncated XZ tails are rejected.
    void finish(archive* cpio) {
        const void* data = nullptr;
        while (!finished) {
            if (next(cpio, &data) < 0) check(ARCHIVE_FATAL, cpio);
        }
    }
};

static int extract(const fs::path& input, const fs::path& output) {
    Reader xar(archive_read_new());
    check(archive_read_support_format_xar(xar.get()), xar.get());
#ifdef _WIN32
    check(archive_read_open_filename_w(xar.get(), input.c_str(), 1024 * 1024), xar.get());
#else
    check(archive_read_open_filename(xar.get(), input.c_str(), 1024 * 1024), xar.get());
#endif
    archive_entry* entry = nullptr;
    bool found = false;
    for (;;) {
        const auto status = archive_read_next_header(xar.get(), &entry);
        if (status == ARCHIVE_EOF) break;
        check(status, xar.get());
        const char* name = archive_entry_pathname(entry);
        if (name && std::string(name) == "Content") { found = true; break; }
        check(archive_read_data_skip(xar.get()), xar.get());
    }
    if (!found) throw std::runtime_error("XIP archive has no Content entry");
    PBZXReader stream(xar.get());
    Reader cpio(archive_read_new());
    check(archive_read_support_format_cpio(cpio.get()), cpio.get());
    // Xcode CPIO stores UTF-8 filenames regardless of the host ANSI code page.
    check(archive_read_set_format_option(cpio.get(), "cpio", "hdrcharset", "UTF-8"), cpio.get());
    check(archive_read_open(cpio.get(), &stream, nullptr,
        [](archive* reader, void* context, const void** buffer) -> la_ssize_t {
            return static_cast<PBZXReader*>(context)->next(reader, buffer);
        }, nullptr), cpio.get());
    std::unique_ptr<archive, DiskDeleter> disk(archive_write_disk_new());
    check(archive_write_disk_set_options(disk.get(),
        ARCHIVE_EXTRACT_TIME | ARCHIVE_EXTRACT_PERM |
        ARCHIVE_EXTRACT_SECURE_NODOTDOT | ARCHIVE_EXTRACT_SECURE_SYMLINKS |
        ARCHIVE_EXTRACT_SECURE_NOABSOLUTEPATHS), disk.get());
    fs::create_directories(output);
    fs::current_path(output);
    DeferredSymlinks symlinks;
    CaseSensitiveDirectories directories;
    DeferredFileModes modes;
    for (;;) {
        const auto status = archive_read_next_header(cpio.get(), &entry);
        if (status == ARCHIVE_EOF) break;
        check(status, cpio.get());
        directories.prepare(entry);
        if (!symlinks.defer(entry)) {
            modes.prepare(entry);
            check(archive_read_extract2(cpio.get(), entry, disk.get()), cpio.get());
        }
    }
    stream.finish(cpio.get());
    symlinks.finish(disk.get());
    check(archive_write_close(disk.get()), disk.get());
    modes.finish();
    check(archive_read_close(cpio.get()), cpio.get());
    return 0;
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
        if (argc != 3) throw std::runtime_error("Usage: xtool-unxip <Xcode.xip> <output-directory>");
        return extract(fs::absolute(argv[1]), fs::absolute(argv[2]));
    } catch (const std::exception& error) {
        std::cerr << "xtool-unxip: " << error.what() << '\n';
        return 1;
    }
}
