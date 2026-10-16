#include "CWindowsADI.h"
#include <stdio.h>

int main(void) {
    if (xadi_GetLoginCode(UINT64_MAX - 1) != -1000002) {
        fputs("Unloaded bridge must return a load error\n", stderr);
        return 1;
    }
    // The test executable lives beside the packaged DLL. An absent Apple-library
    // directory distinguishes successful DLL discovery from a loader failure.
    if (xadi_LoadChecked("Z:/xtool-nonexistent-apple-libraries") != -1000001) {
        fputs("Bridge could not load XADIBinary.dll or propagate its exception\n", stderr);
        return 1;
    }
    puts("Native C-to-D Anisette bridge passed");
    return 0;
}
