// SPDX-FileCopyrightText: 2026 Espressif Systems (Shanghai) CO LTD
// SPDX-License-Identifier: Apache-2.0
//
// libFuzzer target: ggl-svcd's unit file parser, on arbitrary file
// contents. Unit files come from deployments, so their contents are not
// trusted.

// Logging to syslog would dominate the run time: drop it.
#include <syslog.h>
#define syslog(...) ((void) 0)
#define vsyslog(...) ((void) 0)

#define main ggl_svcd_main
#include "ggl-svcd.c"
#undef main

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size);

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    static char path[64];
    if (path[0] == '\0') {
        (void) snprintf(
            path, sizeof(path), "/dev/shm/ggl-svc-fuzz-%ld.service", (long) getpid()
        );
    }
    FILE *f = fopen(path, "w");
    if (f == NULL) {
        return 0;
    }
    (void) fwrite(data, 1, size, f);
    (void) fclose(f);

    static Unit u;
    memset(&u, 0, sizeof(u));
    u.log_fd = -1;
    (void) snprintf(u.name, sizeof(u.name), "ggl.fuzz.service");
    (void) snprintf(u.path, sizeof(u.path), "%s", path);
    (void) parse_unit(&u);
    return 0;
}
