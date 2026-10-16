#include "CWindowsADI.h"
#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <wchar.h>

static HMODULE library;
#define NOT_LOADED (-1000002)

int32_t xadi_LoadChecked(const char *path) {
    if (!library) {
        wchar_t filename[32768];
        DWORD count = GetModuleFileNameW(NULL, filename, 32768);
        if (!count || count >= 32768) return NOT_LOADED;
        wchar_t *last = wcsrchr(filename, L'\\');
        if (!last) return NOT_LOADED;
        const wchar_t suffix[] = L"XADIBinary.dll";
        size_t remaining = 32768 - (size_t)(last + 1 - filename);
        if (remaining < sizeof(suffix) / sizeof(suffix[0])) return NOT_LOADED;
        wcscpy_s(last + 1, remaining, suffix);
        // Only search the packaged DLL directory and normal trusted system paths.
        library = LoadLibraryExW(filename, NULL, LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_DEFAULT_DIRS);
        if (!library) return NOT_LOADED;
    }
    typedef int32_t (*Load)(const char *);
    Load load = (Load)GetProcAddress(library, "xadi_LoadChecked");
    return load ? load(path) : NOT_LOADED;
}

// Resolve the exports from the separately linked LGPL D runtime library. Keeping
// this boundary dynamic also prevents any malloc/free crossing different CRTs.
#define FORWARD(name, signature, arguments) \
    int32_t name signature { \
        typedef int32_t (*Function) signature; \
        Function function = library ? (Function)GetProcAddress(library, #name) : NULL; \
        return function ? function arguments : NOT_LOADED; \
    }

FORWARD(xadi_SetAndroidID, (const char *identifier, uint32_t length), (identifier, length))
FORWARD(xadi_SetProvisioningPath, (const char *path), (path))
FORWARD(xadi_ProvisioningErase, (uint64_t dsId), (dsId))
FORWARD(xadi_Synchronize, (uint64_t dsId, const void *metadata, uint32_t length, void **machine, uint32_t *machineLength, void **resume, uint32_t *resumeLength), (dsId, metadata, length, machine, machineLength, resume, resumeLength))
FORWARD(xadi_ProvisioningDestroy, (uint32_t session), (session))
FORWARD(xadi_ProvisioningEnd, (uint32_t session, const void *ptm, uint32_t ptmLength, const void *key, uint32_t keyLength), (session, ptm, ptmLength, key, keyLength))
FORWARD(xadi_ProvisioningStart, (uint64_t dsId, const void *metadata, uint32_t length, void **client, uint32_t *clientLength, uint32_t *session), (dsId, metadata, length, client, clientLength, session))
FORWARD(xadi_GetLoginCode, (uint64_t dsId), (dsId))
FORWARD(xadi_Dispose, (void *pointer), (pointer))
FORWARD(xadi_OTPRequest, (uint64_t dsId, void **machine, uint32_t *machineLength, void **otp, uint32_t *otpLength), (dsId, machine, machineLength, otp, otpLength))
#endif
