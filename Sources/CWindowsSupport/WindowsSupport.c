#include "CWindowsSupport.h"
#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <io.h>

static volatile LONG interrupted = 0;

static BOOL WINAPI interrupt_handler(DWORD event) {
    if (event != CTRL_C_EVENT && event != CTRL_BREAK_EVENT) return FALSE;
    InterlockedExchange(&interrupted, 1);
    return TRUE;
}

int xtool_try_lock(int fd, int exclusive, uint32_t *error) {
    intptr_t raw = _get_osfhandle(fd);
    if (raw == -1) {
        *error = ERROR_INVALID_HANDLE;
        return -1;
    }
    OVERLAPPED overlapped = {0};
    DWORD flags = LOCKFILE_FAIL_IMMEDIATELY;
    if (exclusive) flags |= LOCKFILE_EXCLUSIVE_LOCK;
    // Lock byte zero, including for empty files, just like flock's advisory lock.
    if (LockFileEx((HANDLE)raw, flags, 0, 1, 0, &overlapped)) return 1;
    *error = GetLastError();
    return *error == ERROR_LOCK_VIOLATION ? 0 : -1;
}

int xtool_install_interrupt_handler(uint32_t *error) {
    InterlockedExchange(&interrupted, 0);
    if (SetConsoleCtrlHandler(interrupt_handler, TRUE)) return 1;
    *error = GetLastError();
    return 0;
}

int xtool_interrupted(void) {
    return InterlockedCompareExchange(&interrupted, 0, 0) != 0;
}

void xtool_remove_interrupt_handler(void) {
    SetConsoleCtrlHandler(interrupt_handler, FALSE);
}
#endif
#ifdef _WIN32
#include <wincrypt.h>
#include <dpapi.h>
int xtool_protect_data(const void *data, uint32_t size, void **output, uint32_t *output_size, uint32_t *error) {
    DATA_BLOB input = {size, (BYTE *)data};
    DATA_BLOB result = {0};
    if (!CryptProtectData(&input, L"xtool", NULL, NULL, NULL, CRYPTPROTECT_UI_FORBIDDEN, &result)) {
        *error = GetLastError();
        return 0;
    }
    *output = result.pbData;
    *output_size = result.cbData;
    return 1;
}
int xtool_unprotect_data(const void *data, uint32_t size, void **output, uint32_t *output_size, uint32_t *error) {
    DATA_BLOB input = {size, (BYTE *)data};
    DATA_BLOB result = {0};
    if (!CryptUnprotectData(&input, NULL, NULL, NULL, NULL, CRYPTPROTECT_UI_FORBIDDEN, &result)) {
        *error = GetLastError();
        return 0;
    }
    *output = result.pbData;
    *output_size = result.cbData;
    return 1;
}
void xtool_release_secret(void *data, uint32_t size) {
    if (data) { SecureZeroMemory(data, size); LocalFree(data); }
}
#endif
