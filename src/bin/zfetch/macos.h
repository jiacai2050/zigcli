#ifndef ZFETCH_MACOS_H
#define ZFETCH_MACOS_H

#include <stddef.h>
#include <stdint.h>

int zfetch_get_battery(char *buffer, size_t buffer_size);

int zfetch_is_dark_theme(void);

int zfetch_get_memory(
    uint64_t *bytes_total,
    uint64_t *pages_app,
    uint64_t *pages_wired,
    uint64_t *pages_compressed
);

#endif
