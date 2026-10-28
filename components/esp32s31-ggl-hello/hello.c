// ESP32-S31 Greengrass Lite demo component.
//
// Proves the core-device path end to end, then reports a heartbeat:
//   1. reads its "message" configuration over Greengrass IPC;
//   2. publishes to a local topic and receives it back (ggpubsubd);
//   3. subscribes to an IoT Core topic, publishes to it and receives the
//      message back through AWS IoT Core (iotcored);
//   4. publishes {uptime, MemAvailable} to IoT Core every interval seconds.
//
// Topics are esp32s31/<thing>/hello (round trip) and
// esp32s31/<thing>/heartbeat. Exit status is non-zero if any check fails.

#include <gg/error.h>
#include <gg/ipc/client.h>
#include <gg/object.h>
#include <gg/sdk.h>
#include <gg/types.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static volatile bool local_received;
static volatile bool cloud_received;

static void on_local(
    void *ctx, GgBuffer topic, GgObject payload, GgIpcSubscriptionHandle handle
) {
    (void) ctx;
    (void) handle;
    if (gg_obj_type(payload) != GG_TYPE_BUF) {
        return;
    }
    GgBuffer message = gg_obj_into_buf(payload);
    printf(
        "hello: local %.*s <- %.*s\n",
        (int) topic.len,
        topic.data,
        (int) message.len,
        message.data
    );
    local_received = true;
}

static void on_cloud(
    void *ctx, GgBuffer topic, GgBuffer payload, GgIpcSubscriptionHandle handle
) {
    (void) ctx;
    (void) handle;
    printf(
        "hello: cloud %.*s <- %.*s\n",
        (int) topic.len,
        topic.data,
        (int) payload.len,
        payload.data
    );
    cloud_received = true;
}

static bool wait_for(volatile bool *flag, int tenths) {
    for (int i = 0; (i < tenths) && !*flag; ++i) {
        usleep(100000);
    }
    return *flag;
}

static long meminfo_kb(const char *key) {
    FILE *f = fopen("/proc/meminfo", "r");
    if (f == NULL) {
        return -1;
    }
    char line[128];
    long value = -1;
    size_t key_len = strlen(key);
    while (fgets(line, sizeof(line), f) != NULL) {
        if ((strncmp(line, key, key_len) == 0) && (line[key_len] == ':')) {
            value = strtol(&line[key_len + 1], NULL, 10);
            break;
        }
    }
    (void) fclose(f);
    return value;
}

static long uptime_s(void) {
    FILE *f = fopen("/proc/uptime", "r");
    if (f == NULL) {
        return -1;
    }
    double up = -1;
    if (fscanf(f, "%lf", &up) != 1) {
        up = -1;
    }
    (void) fclose(f);
    return (long) up;
}

int main(int argc, char **argv) {
    int interval = (argc > 1) ? atoi(argv[1]) : 30;
    const char *thing = getenv("AWS_IOT_THING_NAME");
    if (thing == NULL) {
        fprintf(stderr, "hello: AWS_IOT_THING_NAME is not set\n");
        return 1;
    }
    setvbuf(stdout, NULL, _IOLBF, 0);

    char hello_topic[128];
    char heartbeat_topic[128];
    (void) snprintf(
        hello_topic, sizeof(hello_topic), "esp32s31/%s/hello", thing
    );
    (void) snprintf(
        heartbeat_topic, sizeof(heartbeat_topic), "esp32s31/%s/heartbeat", thing
    );
    GgBuffer hello = { (uint8_t *) hello_topic, strlen(hello_topic) };
    GgBuffer heartbeat = { (uint8_t *) heartbeat_topic,
                           strlen(heartbeat_topic) };

    gg_sdk_init();
    GgError err = ggipc_connect();
    if (err != GG_ERR_OK) {
        fprintf(stderr, "hello: IPC connect failed: %d\n", err);
        return 2;
    }

    uint8_t config_mem[128];
    GgObject config;
    err = ggipc_get_config(
        GG_BUF_LIST(GG_STR("message")), NULL, GG_BUF(config_mem), &config
    );
    if ((err != GG_ERR_OK) || (gg_obj_type(config) != GG_TYPE_BUF)) {
        fprintf(stderr, "hello: config read failed: %d\n", err);
        return 3;
    }
    GgBuffer message = gg_obj_into_buf(config);
    printf("hello: config message=%.*s\n", (int) message.len, message.data);

    GgIpcSubscriptionHandle handle;
    err = ggipc_subscribe_to_topic(
        GG_STR("esp32s31/hello"), on_local, NULL, &handle
    );
    if (err == GG_ERR_OK) {
        err = ggipc_publish_to_topic_binary(GG_STR("esp32s31/hello"), message);
    }
    if ((err != GG_ERR_OK) || !wait_for(&local_received, 50)) {
        fprintf(stderr, "hello: local pub/sub failed: %d\n", err);
        return 4;
    }
    ggipc_close_subscription(handle);

    // A component can start before iotcored has connected (at boot or after
    // a reconnect); subscriptions then fail, so retry for up to a minute.
    for (int attempt = 0; attempt < 30; ++attempt) {
        err = ggipc_subscribe_to_iot_core(hello, 1, on_cloud, NULL, &handle);
        if (err == GG_ERR_OK) {
            break;
        }
        sleep(2);
    }
    if (err == GG_ERR_OK) {
        // The IPC reply can precede the broker's SUBACK.
        sleep(1);
        err = ggipc_publish_to_iot_core(hello, message, 1);
    }
    if ((err != GG_ERR_OK) || !wait_for(&cloud_received, 100)) {
        fprintf(stderr, "hello: IoT Core round trip failed: %d\n", err);
        return 5;
    }
    ggipc_close_subscription(handle);
    puts("hello: PASS");

    while (interval > 0) {
        char payload[160];
        int len = snprintf(
            payload,
            sizeof(payload),
            "{\"thing\":\"%s\",\"uptime_s\":%ld,\"mem_available_kb\":%ld}",
            thing,
            uptime_s(),
            meminfo_kb("MemAvailable")
        );
        GgBuffer body = { (uint8_t *) payload, (size_t) len };
        err = ggipc_publish_to_iot_core(heartbeat, body, 0);
        printf("hello: heartbeat %s (%d)\n", payload, err);
        sleep((unsigned) interval);
    }
    return 0;
}
