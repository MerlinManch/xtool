#ifndef XTOOL_WINDOWS_SUPPORT_H
#define XTOOL_WINDOWS_SUPPORT_H
#include <stdint.h>
// Returns 1 if acquired, 0 if busy, -1 on error. The descriptor owns the lock.
int xtool_try_lock(int fd, int exclusive, uint32_t *error);
int xtool_install_interrupt_handler(uint32_t *error);
int xtool_interrupted(void);
void xtool_remove_interrupt_handler(void);
#ifdef _WIN32
// Buffers returned by these functions must be released with xtool_release_secret.
int xtool_protect_data(const void *data, uint32_t size, void **output, uint32_t *output_size, uint32_t *error);
int xtool_unprotect_data(const void *data, uint32_t size, void **output, uint32_t *output_size, uint32_t *error);
void xtool_release_secret(void *data, uint32_t size);
#endif
#endif
