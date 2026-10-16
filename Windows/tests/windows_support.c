#include "CWindowsSupport.h"
#include <windows.h>
#include <io.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define REQUIRE(value) do { if (!(value)) { fprintf(stderr, "Failed: %s\n", #value); exit(1); } } while (0)

int main(void) {
    wchar_t directory[MAX_PATH];
    wchar_t filename[MAX_PATH];
    REQUIRE(GetTempPathW(MAX_PATH, directory) != 0);
    REQUIRE(GetTempFileNameW(directory, L"xtl", 0, filename) != 0);
    int first = _wopen(filename, _O_RDWR | _O_BINARY);
    int second = _wopen(filename, _O_RDWR | _O_BINARY);
    REQUIRE(first >= 0 && second >= 0);
    uint32_t error = 0;
    REQUIRE(xtool_try_lock(first, 1, &error) == 1);
    REQUIRE(xtool_try_lock(second, 1, &error) == 0);
    REQUIRE(_close(first) == 0);
    REQUIRE(xtool_try_lock(second, 1, &error) == 1);
    REQUIRE(_close(second) == 0);
    REQUIRE(DeleteFileW(filename) != 0);
    REQUIRE(xtool_install_interrupt_handler(&error) != 0);
    REQUIRE(xtool_interrupted() == 0);
    xtool_remove_interrupt_handler();
    const char secret[] = "xtool secret test";
    void *encrypted = NULL, *decrypted = NULL;
    uint32_t encrypted_size = 0, decrypted_size = 0;
    REQUIRE(xtool_protect_data(secret, (uint32_t)sizeof(secret), &encrypted, &encrypted_size, &error) != 0);
    REQUIRE(encrypted_size > sizeof(secret));
    REQUIRE(xtool_unprotect_data(encrypted, encrypted_size, &decrypted, &decrypted_size, &error) != 0);
    REQUIRE(decrypted_size == sizeof(secret));
    REQUIRE(memcmp(decrypted, secret, sizeof(secret)) == 0);
    xtool_release_secret(encrypted, encrypted_size);
    xtool_release_secret(decrypted, decrypted_size);
    puts("Windows locks, handler and DPAPI smoke tests passed");
    return 0;
}
