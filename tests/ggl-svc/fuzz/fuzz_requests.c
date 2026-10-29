// SPDX-FileCopyrightText: 2026 Espressif Systems (Shanghai) CO LTD
// SPDX-License-Identifier: Apache-2.0
//
// libFuzzer target: ggl-svcd's control protocol. Each input line is one
// request; a line starting with '!' comes from root, any other from an
// unprivileged user. A few units are linked before each input, so requests
// act on real state. Verbs that start processes (start, restart,
// start-target) are not sent as root: ggl-svcd would fork.

// Logging to syslog would dominate the run time: drop it.
#include <syslog.h>
#define syslog(...) ((void) 0)
#define vsyslog(...) ((void) 0)

#define main ggl_svcd_main
#include "ggl-svcd.c"
#undef main

#include <sys/socket.h>

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size);

static int sock[2] = { -1, -1 };

static void fixture_file(const char *path, const char *text) {
    FILE *f = fopen(path, "w");
    if (f != NULL) {
        (void) fputs(text, f);
        (void) fclose(f);
    }
}

static void empty_dir(const char *dir) {
    DIR *d = opendir(dir);
    if (d == NULL) {
        return;
    }
    struct dirent *e;
    while ((e = readdir(d)) != NULL) {
        if (e->d_name[0] == '.' && (e->d_name[1] == '\0' || e->d_name[1] == '.')) {
            continue;
        }
        char path[PATH_LEN + NAME_LEN];
        (void) snprintf(path, sizeof(path), "%s/%s", dir, e->d_name);
        (void) unlink(path);
    }
    (void) closedir(d);
}

static void setup(void) {
    (void) socketpair(AF_UNIX, SOCK_STREAM | SOCK_NONBLOCK, 0, sock);
    (void) mkdir(FUZZ_DIR, 0700);
    (void) mkdir(STATE_DIR, 0700);
    (void) mkdir(STATE_DIR "/links", 0700);
    (void) mkdir(STATE_DIR "/units", 0700);
    (void) mkdir(STATE_DIR "/enabled", 0700);
    (void) mkdir(GGL_SVC_CORE_DIR, 0700);
    (void) mkdir(FUZZ_DIR "/units", 0700);
    fixture_file(
        GGL_SVC_CORE_DIR "/ggl.core.a.service",
        "[Service]\nType=exec\nExecStart=/bin/true\n"
    );
    fixture_file(
        FUZZ_DIR "/units/ggl.b.service",
        "[Unit]\nBindsTo=ggl.core.a.service\nAfter=ggl.core.a.service\n"
        "[Service]\nType=notify\nNotifyAccess=all\nRemainAfterExit=true\n"
        "ExecStart=/bin/true\n"
    );
    fixture_file(
        FUZZ_DIR "/units/ggl.c.service",
        "[Service]\nType=oneshot\nRestart=on-failure\nExecStart=/bin/true\n"
    );
}

static void drain(void) {
    char buf[4096];
    while (read(sock[1], buf, sizeof(buf)) > 0) { }
}

static void request(char *line, uid_t uid) {
    handle_request(sock[0], line, uid, getpid());
    drain();
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    if (sock[0] < 0) {
        setup();
    }
    while (n_units > 0) {
        forget_unit(&units[0]);
    }
    n_watchers = 0;
    empty_dir(STATE_DIR "/links");
    empty_dir(STATE_DIR "/units");
    empty_dir(STATE_DIR "/enabled");
    load_all();
    char link_b[] = "link " FUZZ_DIR "/units/ggl.b.service";
    char link_c[] = "link " FUZZ_DIR "/units/ggl.c.service";
    request(link_b, 0);
    request(link_c, 0);

    size_t pos = 0;
    while (pos < size) {
        const uint8_t *nl = memchr(data + pos, '\n', size - pos);
        size_t len = (nl != NULL) ? (size_t) (nl - (data + pos)) : size - pos;
        char line[REQUEST_MAX];
        size_t n = (len < sizeof(line) - 1) ? len : sizeof(line) - 1;
        memcpy(line, data + pos, n);
        line[n] = '\0';
        pos += len + 1;

        uid_t uid = 1000;
        char *req = line;
        if (req[0] == '!') {
            uid = 0;
            req++;
            if ((strncmp(req, "start", 5) == 0) || (strncmp(req, "restart", 7) == 0)) {
                continue;
            }
        }
        request(req, uid);
    }
    return 0;
}
