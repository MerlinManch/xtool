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
