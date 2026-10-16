#include "CWindowsSupport.h"
#include <windows.h>
#include <io.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>

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
    puts("Windows lock and handler smoke tests passed");
    return 0;
}
