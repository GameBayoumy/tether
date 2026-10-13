#define _POSIX_C_SOURCE 200809L
#define _DARWIN_C_SOURCE

#include "link_host.h"

#include "xrsp.h"
#include "xrsp_usb.h"

#include <libusb.h>
#include <math.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define META_VENDOR_ID 0x2833u
#define XRSP_INTERFACE_CLASS 0xffu
#define XRSP_INTERFACE_SUBCLASS 0x8au
#define TOPIC_LEGACY_POSE 3u
#define TOPIC_POSE 34u  /* Horizon OS v207 sends head and controller poses here instead of topic 3 */
#define TOPIC_INPUT 35u /* controller buttons/axes (PoseTrackedController layout) and IPD */
#define TOPIC_VIDEO 5u
#define STOCK_FRAME_DURATION_NS 29502900LL

typedef struct topic_assembly {
    uint8_t *buffer;
    size_t capacity;
    size_t need;
    size_t have;
    bool in_body;
} topic_assembly;

struct qlh_host {
    qlh_state_callback callback;
    void *user;

    pthread_t thread;
    bool thread_started;
    atomic_bool running;
    _Atomic int state;

    /* Guards `connection` against teardown while another thread sends frames. */
    pthread_mutex_t connection_lock;
    xrsp_connection *connection;
    xrsp_usb_device *usb;

    pthread_mutex_t data_lock;
    qlh_pose pose;
    uint64_t pose_count;
    qlh_controller controllers[2];
    float ipd;
    qlh_headset_info info;

    float frame_fov[2][4];

    /* Headset clock = host CLOCK_MONOTONIC + clock_offset_ns, estimated from pose timestamps. */
    int64_t clock_offset_ns;
    bool clock_offset_valid;
    /* Highest sample in the current window; lets the offset follow the headset clock when it drops. */
    int64_t clock_window_max_ns;
    int64_t clock_window_start_ns;
    uint32_t next_frame_id;
    uint64_t streaming_session_id;

    topic_assembly topics[XRSP_TOPIC_COUNT];
    uint32_t echo_index;
    _Atomic uint64_t sent_bytes;
};

/* ---- helpers ---------------------------------------------------------------------------- */

static void
sleep_ms(unsigned ms)
{
    struct timespec ts = {(time_t)(ms / 1000u), (long)(ms % 1000u) * 1000000L};
    nanosleep(&ts, NULL);
}

static int64_t
monotonic_ns(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000000000LL + ts.tv_nsec;
}

static uint32_t
rd32(const uint8_t *p)
{
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static uint64_t
rd64(const uint8_t *p)
{
    return (uint64_t)rd32(p) | ((uint64_t)rd32(p + 4) << 32);
}

static float
rdf32(const uint8_t *p)
{
    uint32_t bits = rd32(p);
    float value;
    memcpy(&value, &bits, sizeof(value));
    return value;
}

static void
wr32(uint8_t *p, uint32_t v)
{
    p[0] = (uint8_t)v;
    p[1] = (uint8_t)(v >> 8);
    p[2] = (uint8_t)(v >> 16);
    p[3] = (uint8_t)(v >> 24);
}

static void
wr64(uint8_t *p, uint64_t v)
{
    wr32(p, (uint32_t)v);
    wr32(p + 4, (uint32_t)(v >> 32));
}

static void
set_state(qlh_host *host, qlh_state state, const char *detail)
{
    int previous = atomic_exchange(&host->state, (int)state);
    if (previous != (int)state && host->callback != NULL) {
        host->callback(host->user, state, detail != NULL ? detail : "");
    }
}

/* ---- USB discovery ---------------------------------------------------------------------- */

/* Finds the XRSP interface of the first Meta device. Returns false when none is attached. */
static bool
find_xrsp_device(uint16_t *out_pid, int *out_interface)
{
    libusb_context *ctx = NULL;
    libusb_device **list = NULL;
    ssize_t count;
    bool found = false;

    if (libusb_init(&ctx) != LIBUSB_SUCCESS) {
        return false;
    }
    count = libusb_get_device_list(ctx, &list);
    for (ssize_t i = 0; i < count && !found; i++) {
        struct libusb_device_descriptor desc;
        struct libusb_config_descriptor *config = NULL;
        if (libusb_get_device_descriptor(list[i], &desc) != LIBUSB_SUCCESS || desc.idVendor != META_VENDOR_ID) {
            continue;
        }
        if (libusb_get_active_config_descriptor(list[i], &config) != LIBUSB_SUCCESS || config == NULL) {
            continue;
        }
        for (int n = 0; n < config->bNumInterfaces && !found; n++) {
            for (int a = 0; a < config->interface[n].num_altsetting; a++) {
                const struct libusb_interface_descriptor *alt = &config->interface[n].altsetting[a];
                if (alt->bInterfaceClass == XRSP_INTERFACE_CLASS && alt->bInterfaceSubClass == XRSP_INTERFACE_SUBCLASS) {
                    *out_pid = desc.idProduct;
                    *out_interface = alt->bInterfaceNumber;
                    found = true;
                    break;
                }
            }
        }
        libusb_free_config_descriptor(config);
    }
    libusb_free_device_list(list, 1);
    libusb_exit(ctx);
    return found;
}

/* xrspd only sends its basic-session INVITE after it sees a fresh host attach. */
static void
reset_device(uint16_t pid)
{
    libusb_context *ctx = NULL;
    libusb_device_handle *handle;

    if (libusb_init(&ctx) != LIBUSB_SUCCESS) {
        return;
    }
    handle = libusb_open_device_with_vid_pid(ctx, META_VENDOR_ID, pid);
    if (handle != NULL) {
        (void)libusb_reset_device(handle);
        libusb_close(handle);
    }
    libusb_exit(ctx);
}

/* ---- pairing ---------------------------------------------------------------------------- */

static xrsp_result
send_builtin_words(xrsp_connection *connection, xrsp_builtin_type type, const uint8_t *words, size_t bytes)
{
    uint8_t buffer[128];
    wr32(buffer, 0);
    wr32(buffer + 4, (uint32_t)(bytes / 8));
    memcpy(buffer + 8, words, bytes);
    return xrsp_send_builtin(connection, type, 200, buffer, bytes + 8);
}

/* Host messages after the basic ACK, from the Monado quest_link driver (Max Thomas). */
static xrsp_result
send_code_generation(xrsp_connection *connection)
{
    static const uint8_t words[] = {0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00,
                                    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00};
    return send_builtin_words(connection, XRSP_BUILTIN_CODE_GENERATION, words, sizeof(words));
}

static xrsp_result
send_pairing(xrsp_connection *connection)
{
    static const uint8_t words[] = {0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00,
                                    0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00};
    return send_builtin_words(connection, XRSP_BUILTIN_PAIRING, words, sizeof(words));
}

static xrsp_result
send_echo_ping(qlh_host *host)
{
    uint8_t buffer[8 + 32];
    uint32_t word0 = (uint32_t)XRSP_BUILTIN_ECHO | (uint32_t)((32u * 0x1000u + 0xb000u) & 0xffffc000u);
    wr32(buffer, word0);
    wr32(buffer + 4, host->echo_index++);
    wr64(buffer + 8, 0);
    wr64(buffer + 16, 0);
    wr64(buffer + 24, (uint64_t)monotonic_ns());
    wr64(buffer + 32, 0);
    return xrsp_send_packet(host->connection, XRSP_TOPIC_BUILTIN, buffer, sizeof(buffer));
}

static xrsp_result
finish_pairing(qlh_host *host)
{
    static const uint8_t video_request[] = {0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00,
                                            0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00};
    uint8_t buffer[8 + sizeof(video_request)];
    xrsp_result result = send_echo_ping(host);
    if (result != XRSP_SUCCESS) {
        return result;
    }
    wr32(buffer, 0);
    wr32(buffer + 4, (uint32_t)(sizeof(video_request) / 8));
    memcpy(buffer + 8, video_request, sizeof(video_request));
    return xrsp_topic_write(host->connection, TOPIC_VIDEO, buffer, sizeof(buffer));
}

/*
 * The streaming INVITE carries the headset description. Rather than depend on a
 * Cap'n Proto schema that shifts between OS releases, locate the two lens records
 * (four angles in degrees each, 48 bytes apart) and the display size + refresh rate.
 */
static void
parse_headset_info(qlh_host *host, const uint8_t *payload, size_t bytes)
{
    qlh_headset_info info;
    bool have_lens = false;
    bool have_display = false;

    memset(&info, 0, sizeof(info));
    for (size_t off = 0; off + 64 <= bytes && !have_lens; off += 4) {
        bool plausible = true;
        for (size_t k = 0; k < 4; k++) {
            float a = rdf32(payload + off + k * 4), b = rdf32(payload + off + 48 + k * 4);
            if (!(a > 15.0f && a < 80.0f && b > 15.0f && b < 80.0f)) {
                plausible = false;
                break;
            }
        }
        if (plausible) {
            for (int eye = 0; eye < 2; eye++) {
                const uint8_t *lens = payload + off + (size_t)eye * 48;
                info.eye_fov[eye].up = rdf32(lens);
                info.eye_fov[eye].down = rdf32(lens + 4);
                info.eye_fov[eye].left = rdf32(lens + 8);
                info.eye_fov[eye].right = rdf32(lens + 12);
            }
            have_lens = true;
        }
    }
    for (size_t off = 0; off + 12 <= bytes && !have_display; off += 4) {
        uint32_t w = rd32(payload + off), h = rd32(payload + off + 4);
        float hz = rdf32(payload + off + 8);
        if (w >= 1000 && w <= 8000 && h >= 1000 && h <= 8000 && hz >= 50.0f && hz <= 150.0f) {
            info.display_width = w;
            info.display_height = h;
            info.refresh_hz = hz;
            have_display = true;
        }
    }
    if (!have_lens) {
        /* Quest 3 defaults */
        info.eye_fov[0] = (qlh_fov){44.0f, 55.0f, 54.0f, 40.0f};
        info.eye_fov[1] = (qlh_fov){44.0f, 55.0f, 40.0f, 54.0f};
    }
    if (!have_display) {
        info.display_width = 4128;
        info.display_height = 2208;
        info.refresh_hz = 72.0f;
    }
    info.valid = true;
    pthread_mutex_lock(&host->data_lock);
    host->info = info;
    pthread_mutex_unlock(&host->data_lock);
}

/* ---- poses ------------------------------------------------------------------------------ */

/* Resolves a Cap'n Proto struct pointer at word `at`. */
static bool
capnp_struct(const uint8_t *msg, size_t words, size_t at, size_t *out_start, uint16_t *out_data, uint16_t *out_ptrs)
{
    uint32_t lo, hi;
    int32_t offset;
    size_t start;

    if (at >= words) {
        return false;
    }
    lo = rd32(msg + at * 8);
    hi = rd32(msg + at * 8 + 4);
    if ((lo & 3u) != 0) {
        return false;
    }
    offset = (int32_t)lo >> 2;
    if ((int64_t)at + 1 + offset < 0) {
        return false;
    }
    start = (size_t)((int64_t)at + 1 + offset);
    *out_data = (uint16_t)(hi & 0xffffu);
    *out_ptrs = (uint16_t)(hi >> 16);
    if (start + *out_data + *out_ptrs > words) {
        return false;
    }
    *out_start = start;
    return true;
}

/* Resolves a Cap'n Proto composite list pointer at word `at`. */
static bool
capnp_composite_list(const uint8_t *msg, size_t words, size_t at, size_t *out_first, uint32_t *out_count,
                     uint16_t *out_data, uint16_t *out_ptrs)
{
    uint32_t lo, hi, count;
    size_t tag;
    uint16_t data, ptrs;

    if (at >= words) {
        return false;
    }
    lo = rd32(msg + at * 8);
    hi = rd32(msg + at * 8 + 4);
    if ((lo & 3u) != 1 || (hi & 7u) != 7) {
        return false;
    }
    tag = (size_t)((int64_t)at + 1 + ((int32_t)lo >> 2));
    if (tag >= words) {
        return false;
    }
    count = rd32(msg + tag * 8) >> 2;
    data = (uint16_t)(rd32(msg + tag * 8 + 4) & 0xffffu);
    ptrs = (uint16_t)(rd32(msg + tag * 8 + 4) >> 16);
    if (count > 8 || tag + 1 + (size_t)count * (data + ptrs) > words) {
        return false;
    }
    *out_first = tag + 1;
    *out_count = count;
    *out_data = data;
    *out_ptrs = ptrs;
    return true;
}

/* OvrPoseF: 19 floats (velocities, accelerations, quat at +48, position at +64), timestamp at +80. */
static bool
read_ovr_pose(const uint8_t *msg, size_t words, size_t pointer_word, qlh_pose *out)
{
    size_t start;
    uint16_t data, ptrs;
    float norm;
    if (!capnp_struct(msg, words, pointer_word, &start, &data, &ptrs) || data < 11) {
        return false;
    }
    const uint8_t *p = msg + start * 8;
    for (int i = 0; i < 4; i++) {
        out->orientation[i] = rdf32(p + 48 + (size_t)i * 4);
    }
    for (int i = 0; i < 3; i++) {
        out->position[i] = rdf32(p + 64 + (size_t)i * 4);
    }
    out->timestamp_ns = (int64_t)rd64(p + 80);
    norm = sqrtf(out->orientation[0] * out->orientation[0] + out->orientation[1] * out->orientation[1] +
                 out->orientation[2] * out->orientation[2] + out->orientation[3] * out->orientation[3]);
    return fabsf(norm - 1.0f) <= 0.05f;
}

/* Topic 35: root { u32 flags; f32 ?; f32 ipd; ... ; controllers: List(PoseTrackedController) }. */
static void
handle_input_message(qlh_host *host, const uint8_t *msg, size_t bytes)
{
    size_t words = bytes / 8, root, first;
    uint16_t root_data, root_ptrs, data, ptrs;
    uint32_t count;

    if (!capnp_struct(msg, words, 0, &root, &root_data, &root_ptrs) || root_ptrs < 1) {
        return;
    }
    pthread_mutex_lock(&host->data_lock);
    if (root_data >= 2) {
        float ipd = rdf32(msg + root * 8 + 8);
        if (ipd > 0.045f && ipd < 0.085f) {
            host->ipd = ipd;
        }
    }
    if (capnp_composite_list(msg, words, root + root_data, &first, &count, &data, &ptrs) && data >= 4) {
        for (uint32_t i = 0; i < count; i++) {
            const uint8_t *e = msg + (first + (size_t)i * (data + ptrs)) * 8;
            uint32_t features = rd32(e);
            qlh_controller *c = &host->controllers[(features & 1u) ? 1 : 0];
            c->valid = true;
            c->right = (features & 1u) != 0;
            c->battery = (uint8_t)((features >> 8) & 0x7fu);
            c->buttons = rd32(e + 4);
            c->touches = rd32(e + 8);
            c->trigger = 1.0f - rdf32(e + 12);
            c->grip = 1.0f - rdf32(e + 16);
            c->stick_x = rdf32(e + 20);
            c->stick_y = rdf32(e + 24);
        }
    }
    pthread_mutex_unlock(&host->data_lock);
}

/* Development aid: TETHER_DUMP_POSES=<dir> saves every 25th pose message (up to 400). */
static void
dump_pose_message(const uint8_t *msg, size_t bytes)
{
    static unsigned seen, written;
    const char *dir = getenv("TETHER_DUMP_POSES");
    char path[512];
    FILE *f;
    if (dir == NULL || written >= 400 || (seen++ % 25) != 0) {
        return;
    }
    snprintf(path, sizeof(path), "%s/pose_%04u.bin", dir, written++);
    if ((f = fopen(path, "wb")) != NULL) {
        fwrite(msg, 1, bytes, f);
        fclose(f);
    }
}

/* PayloadPose: root struct whose second pointer is the headset OvrPoseF (11 data words). */
static void
handle_pose_message(qlh_host *host, const uint8_t *msg, size_t bytes)
{
    size_t words = bytes / 8, root, head;
    uint16_t root_data, root_ptrs, head_data, head_ptrs;
    qlh_pose pose;
    float norm;

    dump_pose_message(msg, bytes);
    if (!capnp_struct(msg, words, 0, &root, &root_data, &root_ptrs) || root_ptrs < 2) {
        return;
    }
    if (!capnp_struct(msg, words, root + root_data + 1, &head, &head_data, &head_ptrs) || head_data < 11) {
        return;
    }
    const uint8_t *p = msg + head * 8;
    for (int i = 0; i < 4; i++) {
        pose.orientation[i] = rdf32(p + 48 + (size_t)i * 4);
    }
    for (int i = 0; i < 3; i++) {
        pose.position[i] = rdf32(p + 64 + (size_t)i * 4);
    }
    pose.timestamp_ns = (int64_t)rd64(p + 80);
    norm = sqrtf(pose.orientation[0] * pose.orientation[0] + pose.orientation[1] * pose.orientation[1] +
                 pose.orientation[2] * pose.orientation[2] + pose.orientation[3] * pose.orientation[3]);
    if (fabsf(norm - 1.0f) > 0.05f) {
        return;
    }
    pthread_mutex_lock(&host->data_lock);
    host->pose = pose;
    host->pose_count++;
    {
        /* Track the highest (pose time - arrival time): transport delay only ever makes it smaller.
         * Rises are taken at once (the headset clock jumps ahead after it sleeps); drops are taken
         * from each half-second window's maximum. */
        int64_t now = monotonic_ns();
        int64_t sample = pose.timestamp_ns - now;
        if (!host->clock_offset_valid || sample > host->clock_offset_ns) {
            host->clock_offset_ns = sample;
            host->clock_offset_valid = true;
        }
        if (host->clock_window_start_ns == 0 || sample > host->clock_window_max_ns) {
            host->clock_window_max_ns = sample;
        }
        if (host->clock_window_start_ns == 0) {
            host->clock_window_start_ns = now;
        } else if (now - host->clock_window_start_ns >= 500000000) {
            host->clock_offset_ns = host->clock_window_max_ns;
            host->clock_window_start_ns = now;
            host->clock_window_max_ns = sample;
        }
    }
    /* Controllers: root pointer 0 is a list of { u32 side; OvrPoseF pose; ... }. */
    {
        size_t first;
        uint32_t count;
        uint16_t data, ptrs;
        if (capnp_composite_list(msg, words, root + root_data, &first, &count, &data, &ptrs) && data >= 1 && ptrs >= 1) {
            for (uint32_t i = 0; i < count; i++) {
                size_t element = first + (size_t)i * (data + ptrs);
                uint32_t side = rd32(msg + element * 8);
                qlh_pose controller_pose;
                if (side <= 1 && read_ovr_pose(msg, words, element + data, &controller_pose)) {
                    host->controllers[side].pose = controller_pose;
                    host->controllers[side].pose_valid = true;
                }
            }
        }
    }
    pthread_mutex_unlock(&host->data_lock);
}

/* Pose topics carry segmented messages: an 8-byte segment table, then the segment words. */
static void
handle_segmented_packet(qlh_host *host, uint8_t topic, const uint8_t *data, size_t bytes)
{
    topic_assembly *t = &host->topics[topic];

    while (bytes > 0) {
        if (!t->in_body) {
            uint32_t words;
            if (bytes < 8) {
                return;
            }
            words = rd32(data + 4);
            data += 8;
            bytes -= 8;
            if (words == 0 || words > 65536u) {
                continue;
            }
            t->need = (size_t)words * 8;
            t->have = 0;
            if (t->capacity < t->need) {
                uint8_t *grown = realloc(t->buffer, t->need);
                if (grown == NULL) {
                    return;
                }
                t->buffer = grown;
                t->capacity = t->need;
            }
            t->in_body = true;
            continue;
        }
        size_t take = t->need - t->have < bytes ? t->need - t->have : bytes;
        memcpy(t->buffer + t->have, data, take);
        t->have += take;
        data += take;
        bytes -= take;
        if (t->have == t->need) {
            t->in_body = false;
            if (topic == TOPIC_INPUT) {
                handle_input_message(host, t->buffer, t->need);
            } else {
                handle_pose_message(host, t->buffer, t->need);
            }
        }
    }
}

/* Development aid: TETHER_DUMP_TOPICS=<dir> appends inbound packets to <dir>/tNN.log as
 * [u32 ms since start][u32 length][payload] (pose, padding and builtin topics excluded). */
static void
dump_topic_packet(const xrsp_packet *packet)
{
    static FILE *files[XRSP_TOPIC_COUNT];
    static int64_t start_ns;
    const char *dir = getenv("TETHER_DUMP_TOPICS");
    uint8_t header[8];
    if (dir == NULL || packet->topic == 0 || packet->topic == XRSP_TOPIC_BUILTIN || packet->topic == TOPIC_POSE ||
        packet->topic >= XRSP_TOPIC_COUNT) {
        return;
    }
    if (start_ns == 0) {
        start_ns = monotonic_ns();
    }
    if (files[packet->topic] == NULL) {
        char path[512];
        snprintf(path, sizeof(path), "%s/t%02u.log", dir, packet->topic);
        files[packet->topic] = fopen(path, "wb");
        if (files[packet->topic] == NULL) {
            return;
        }
    }
    wr32(header, (uint32_t)((monotonic_ns() - start_ns) / 1000000));
    wr32(header + 4, (uint32_t)packet->payload_bytes);
    fwrite(header, 1, sizeof(header), files[packet->topic]);
    fwrite(packet->payload, 1, packet->payload_bytes, files[packet->topic]);
    fflush(files[packet->topic]);
}

/* ---- session ---------------------------------------------------------------------------- */

static void
reset_session_data(qlh_host *host)
{
    pthread_mutex_lock(&host->data_lock);
    host->pose_count = 0;
    memset(&host->pose, 0, sizeof(host->pose));
    memset(host->controllers, 0, sizeof(host->controllers));
    pthread_mutex_unlock(&host->data_lock);
}

/* Host thread only: the assemblies are owned by the receive loop. */
static void
reset_topic_assembly(qlh_host *host)
{
    for (size_t i = 0; i < XRSP_TOPIC_COUNT; i++) {
        host->topics[i].in_body = false;
    }
}

static xrsp_result
handle_builtin(qlh_host *host, const xrsp_packet *packet)
{
    xrsp_builtin_message message;
    xrsp_result result = xrsp_builtin_decode(packet->payload, packet->payload_bytes, &message);

    if (result != XRSP_SUCCESS) {
        return XRSP_SUCCESS;
    }
    switch (message.type) {
    case XRSP_BUILTIN_ECHO:
        return xrsp_send_packet(host->connection, XRSP_TOPIC_BUILTIN, packet->payload, packet->payload_bytes);
    case XRSP_BUILTIN_CODE_GENERATION_ACK:
        return send_pairing(host->connection);
    case XRSP_BUILTIN_PAIRING_ACK:
        result = finish_pairing(host);
        if (result == XRSP_SUCCESS) {
            set_state(host, QLH_STATE_HOST_CONNECTED, "Paired; waiting for Launch in the headset");
        }
        return result;
    case XRSP_BUILTIN_BYE:
        if (atomic_load(&host->state) == QLH_STATE_STREAMING) {
            reset_session_data(host);
            reset_topic_assembly(host);
            set_state(host, QLH_STATE_HOST_CONNECTED, "Quest Link closed in the headset");
        }
        return XRSP_SUCCESS;
    case XRSP_BUILTIN_INVITE:
    case XRSP_BUILTIN_ACK: {
        xrsp_handshake handshake;
        memset(&handshake, 0, sizeof(handshake));
        result = xrsp_parse_handshake(message.capnp_payload, message.capnp_payload_bytes, &handshake);
        if (result != XRSP_SUCCESS) {
            return XRSP_SUCCESS;
        }
        if (message.type == XRSP_BUILTIN_INVITE) {
            if (handshake.session_type == XRSP_SESSION_STREAMING) {
                parse_headset_info(host, message.capnp_payload, message.capnp_payload_bytes);
            }
            result = xrsp_send_stock_client_invite_ok(host->connection, &handshake);
        } else if (handshake.session_type == XRSP_SESSION_BASIC) {
            if (getenv("TETHER_DEV_SKIP_PAIRING") != NULL) {
                /* Development only: no Launch prompt, so the client can be started over adb. */
                set_state(host, QLH_STATE_HOST_CONNECTED, "Paired (development mode)");
            } else {
                result = send_code_generation(host->connection);
            }
        } else if (handshake.session_type == XRSP_SESSION_STREAMING) {
            pthread_mutex_lock(&host->data_lock);
            host->streaming_session_id = handshake.session_id;
            pthread_mutex_unlock(&host->data_lock);
            reset_session_data(host);
            reset_topic_assembly(host);
            set_state(host, QLH_STATE_STREAMING, "Quest Link is running");
        }
        xrsp_handshake_release(&handshake);
        return result;
    }
    default:
        return XRSP_SUCCESS;
    }
}

static void
close_connection(qlh_host *host)
{
    pthread_mutex_lock(&host->connection_lock);
    if (host->connection != NULL) {
        xrsp_connection_destroy(host->connection);
        host->connection = NULL;
    }
    if (host->usb != NULL) {
        xrsp_usb_close(host->usb);
        host->usb = NULL;
    }
    pthread_mutex_unlock(&host->connection_lock);
}

typedef struct pairing_watchdog {
    qlh_host *host;
    xrsp_connection *connection;
} pairing_watchdog;

/* xrspd sometimes stays silent after a reset (e.g. right after a session ended). If no pairing has
 * happened within a few seconds, interrupt the read so run_session returns and the host resets again.
 * run_session joins this thread after closing its connection, so the host always outlives it. */
static void *
pairing_watchdog_thread(void *user)
{
    pairing_watchdog *watchdog = user;
    qlh_host *host = watchdog->host;
    for (int i = 0; i < 70; i++) {
        bool current;
        sleep_ms(100);
        pthread_mutex_lock(&host->connection_lock);
        current = host->connection == watchdog->connection;
        pthread_mutex_unlock(&host->connection_lock);
        if (!current || !atomic_load(&host->running) || atomic_load(&host->state) != QLH_STATE_CONNECTING) {
            return NULL;
        }
    }
    pthread_mutex_lock(&host->connection_lock);
    if (host->connection == watchdog->connection && atomic_load(&host->state) == QLH_STATE_CONNECTING) {
        (void)xrsp_connection_interrupt(watchdog->connection);
    }
    pthread_mutex_unlock(&host->connection_lock);
    return NULL;
}

static void
run_session(qlh_host *host, uint16_t pid, int interface_number)
{
    xrsp_usb_options options;
    xrsp_io io;
    xrsp_config config;
    xrsp_usb_device *usb = NULL;
    xrsp_connection *connection = NULL;
    pairing_watchdog watchdog;
    pthread_t watchdog_thread;
    bool watchdog_started;

    set_state(host, QLH_STATE_CONNECTING, "Connecting to the headset");
    reset_device(pid);
    sleep_ms(2000);

    xrsp_usb_options_init(&options);
    options.vendor_id = META_VENDOR_ID;
    options.interface_number = interface_number;
    /* After a reset the product ID can change, so match any Meta device. */
    for (int attempt = 0; attempt < 20 && atomic_load(&host->running); attempt++) {
        memset(&io, 0, sizeof(io));
        if (xrsp_usb_open(&options, &usb, &io) == XRSP_SUCCESS) {
            break;
        }
        usb = NULL;
        sleep_ms(250);
    }
    if (usb == NULL) {
        return;
    }
    xrsp_config_init(&config);
    config.write_alignment = XRSP_USB_CHUNK_BYTES;
    config.max_payload_bytes = 0xff00;
    if (xrsp_connection_create(&io, &config, &connection) != XRSP_SUCCESS) {
        xrsp_usb_close(usb);
        return;
    }
    pthread_mutex_lock(&host->connection_lock);
    host->usb = usb;
    host->connection = connection;
    pthread_mutex_unlock(&host->connection_lock);
    reset_session_data(host);
    reset_topic_assembly(host);

    watchdog.host = host;
    watchdog.connection = connection;
    watchdog_started = pthread_create(&watchdog_thread, NULL, pairing_watchdog_thread, &watchdog) == 0;
    while (atomic_load(&host->running)) {
        xrsp_packet packet;
        xrsp_result result;

        memset(&packet, 0, sizeof(packet));
        result = xrsp_receive_packet(connection, &packet);
        if (result != XRSP_SUCCESS) {
            break;
        }
        dump_topic_packet(&packet);
        if (packet.topic == XRSP_TOPIC_BUILTIN) {
            result = handle_builtin(host, &packet);
        } else if (packet.topic == TOPIC_POSE || packet.topic == TOPIC_LEGACY_POSE || packet.topic == TOPIC_INPUT) {
            handle_segmented_packet(host, packet.topic, packet.payload, packet.payload_bytes);
        }
        xrsp_packet_release(&packet);
        if (result != XRSP_SUCCESS) {
            break;
        }
    }
    close_connection(host);
    if (watchdog_started) {
        pthread_join(watchdog_thread, NULL);
    }
}

static void *
host_thread(void *user)
{
    qlh_host *host = user;

    while (atomic_load(&host->running)) {
        uint16_t pid = 0;
        int interface_number = 0;
        if (!find_xrsp_device(&pid, &interface_number)) {
            set_state(host, QLH_STATE_WAITING_FOR_DEVICE, "Connect a Quest with a USB cable");
            sleep_ms(1000);
            continue;
        }
        run_session(host, pid, interface_number);
        if (atomic_load(&host->running)) {
            set_state(host, QLH_STATE_WAITING_FOR_DEVICE, "Headset disconnected");
            sleep_ms(1500);
        }
    }
    set_state(host, QLH_STATE_STOPPED, "Quest Link is off");
    return NULL;
}

/* ---- public API ------------------------------------------------------------------------- */

qlh_host *
qlh_create(qlh_state_callback callback, void *user)
{
    qlh_host *host = calloc(1, sizeof(*host));
    if (host == NULL) {
        return NULL;
    }
    host->callback = callback;
    host->user = user;
    atomic_store(&host->state, QLH_STATE_STOPPED);
    for (int eye = 0; eye < 2; eye++) {
        for (int edge = 0; edge < 4; edge++) {
            host->frame_fov[eye][edge] = 1.0f;
        }
    }
    pthread_mutex_init(&host->connection_lock, NULL);
    pthread_mutex_init(&host->data_lock, NULL);
    return host;
}

void
qlh_destroy(qlh_host *host)
{
    if (host == NULL) {
        return;
    }
    qlh_stop(host);
    for (size_t i = 0; i < XRSP_TOPIC_COUNT; i++) {
        free(host->topics[i].buffer);
    }
    pthread_mutex_destroy(&host->connection_lock);
    pthread_mutex_destroy(&host->data_lock);
    free(host);
}

bool
qlh_start(qlh_host *host)
{
    if (host == NULL || host->thread_started) {
        return host != NULL;
    }
    atomic_store(&host->running, true);
    if (pthread_create(&host->thread, NULL, host_thread, host) != 0) {
        atomic_store(&host->running, false);
        return false;
    }
    host->thread_started = true;
    return true;
}

void
qlh_stop(qlh_host *host)
{
    if (host == NULL || !host->thread_started) {
        return;
    }
    atomic_store(&host->running, false);
    pthread_mutex_lock(&host->connection_lock);
    if (host->connection != NULL) {
        (void)xrsp_connection_interrupt(host->connection);
    }
    pthread_mutex_unlock(&host->connection_lock);
    pthread_join(host->thread, NULL);
    host->thread_started = false;
}

qlh_state
qlh_get_state(const qlh_host *host)
{
    return host != NULL ? (qlh_state)atomic_load(&((qlh_host *)host)->state) : QLH_STATE_STOPPED;
}

bool
qlh_get_pose(qlh_host *host, qlh_pose *out_pose, uint64_t *out_pose_count)
{
    bool valid;
    pthread_mutex_lock(&host->data_lock);
    valid = host->pose_count > 0;
    if (out_pose != NULL) {
        *out_pose = host->pose;
    }
    if (out_pose_count != NULL) {
        *out_pose_count = host->pose_count;
    }
    pthread_mutex_unlock(&host->data_lock);
    return valid;
}

bool
qlh_get_controllers(qlh_host *host, qlh_controller out_controllers[2])
{
    bool any;
    pthread_mutex_lock(&host->data_lock);
    memcpy(out_controllers, host->controllers, sizeof(host->controllers));
    any = host->controllers[0].valid || host->controllers[1].valid ||
          host->controllers[0].pose_valid || host->controllers[1].pose_valid;
    pthread_mutex_unlock(&host->data_lock);
    return any;
}

float
qlh_get_ipd(qlh_host *host)
{
    float ipd;
    pthread_mutex_lock(&host->data_lock);
    ipd = host->ipd;
    pthread_mutex_unlock(&host->data_lock);
    return ipd;
}

bool
qlh_get_headset_info(qlh_host *host, qlh_headset_info *out_info)
{
    pthread_mutex_lock(&host->data_lock);
    *out_info = host->info;
    pthread_mutex_unlock(&host->data_lock);
    return out_info->valid;
}

bool
qlh_send_frame(qlh_host *host, uint32_t frame_id, const qlh_pose *pose, const qlh_slice slices[QLH_SLICE_COUNT])
{
    bool ok = true;
    uint64_t bytes = 0;
    float refresh_hz;
    bool clock_offset_valid;
    int64_t clock_offset_ns;

    if (atomic_load(&host->state) != QLH_STATE_STREAMING) {
        return false;
    }
    pthread_mutex_lock(&host->data_lock);
    refresh_hz = host->info.refresh_hz;
    clock_offset_valid = host->clock_offset_valid;
    clock_offset_ns = host->clock_offset_ns;
    pthread_mutex_unlock(&host->data_lock);
    pthread_mutex_lock(&host->connection_lock);
    if (host->connection == NULL) {
        pthread_mutex_unlock(&host->connection_lock);
        return false;
    }
    /* Frame timing on the headset clock (Monado's PayloadSlice): send start now, GPU end one
     * period ahead, display deadline two periods (+ pipeline delta) ahead. Stamping these with the
     * pose time made every frame look ~20 ms late, so the client dropped them. */
    int64_t period = 13888889;
    if (refresh_hz > 1.0f) {
        period = (int64_t)(1000000000.0 / refresh_hz);
    }
    const int64_t pipeline_delta = 4000000;
    int64_t base = clock_offset_valid ? monotonic_ns() + clock_offset_ns : pose->timestamp_ns;
    /* One increasing frame number, whether the frame came from Tether or from an OpenXR app. */
    (void)frame_id;
    uint32_t id = ++host->next_frame_id;

    for (uint32_t i = 0; i < QLH_SLICE_COUNT && ok; i++) {
        xrsp_encoded_slice slice;
        memset(&slice, 0, sizeof(slice));
        slice.frame_id = id;
        memcpy(slice.orientation, pose->orientation, sizeof(slice.orientation));
        memcpy(slice.translation, pose->position, sizeof(slice.translation));
        slice.frame_timestamp_ns = pose->timestamp_ns;
        slice.slice_index = (uint8_t)i;
        /* bit 0: slice carries codec config, bit 1: last slice of the frame */
        slice.slice_flags = (uint8_t)((slices[i].codec_config_bytes != 0 ? 1u : 0u) | (i + 1u == QLH_SLICE_COUNT ? 2u : 0u));
        slice.slice_y = i * QLH_SLICE_HEIGHT;
        slice.slice_data_38 = QLH_SLICE_HEIGHT / 16u;
        slice.slice_timestamp_ns = base;
        slice.slice_duration_ns = pipeline_delta;
        slice.frame_timing_2_ns = base + period;                          /* estimated GPU end */
        slice.frame_timing_1_ns = base + 2 * period + pipeline_delta;     /* display deadline */
        slice.frame_timing_0_ns = base + 2 * period + 2 * pipeline_delta;
        memcpy(slice.fov, host->frame_fov, sizeof(slice.fov));
        ok = xrsp_send_encoded_slice(host->connection, &slice, slices[i].codec_config, slices[i].codec_config_bytes,
                                     slices[i].video, slices[i].video_bytes) == XRSP_SUCCESS;
        bytes += slices[i].codec_config_bytes + slices[i].video_bytes;
    }
    pthread_mutex_unlock(&host->connection_lock);
    atomic_fetch_add(&host->sent_bytes, bytes);
    return ok;
}

void
qlh_set_frame_fov(qlh_host *host, const float tangents[2][4])
{
    pthread_mutex_lock(&host->connection_lock);
    memcpy(host->frame_fov, tangents, sizeof(host->frame_fov));
    pthread_mutex_unlock(&host->connection_lock);
}

bool
qlh_end_streaming(qlh_host *host)
{
    uint8_t *payload = NULL;
    size_t payload_bytes = 0;
    bool ok = false;
    uint64_t session_id;

    if (atomic_load(&host->state) != QLH_STATE_STREAMING) {
        return false;
    }
    pthread_mutex_lock(&host->data_lock);
    session_id = host->streaming_session_id;
    pthread_mutex_unlock(&host->data_lock);
    /* BYE carries the same { session type, session id } envelope the headset uses for its own BYE. */
    if (xrsp_build_session_envelope(session_id, XRSP_SESSION_STREAMING, &payload, &payload_bytes) != XRSP_SUCCESS) {
        return false;
    }
    pthread_mutex_lock(&host->connection_lock);
    if (host->connection != NULL) {
        ok = xrsp_send_builtin(host->connection, XRSP_BUILTIN_BYE, 200, payload, payload_bytes) == XRSP_SUCCESS;
    }
    pthread_mutex_unlock(&host->connection_lock);
    xrsp_free(payload);
    if (ok) {
        reset_session_data(host);
        set_state(host, QLH_STATE_HOST_CONNECTED, "Quest Link ended from this Mac");
    }
    return ok;
}

uint64_t
qlh_take_sent_bytes(qlh_host *host)
{
    return atomic_exchange(&host->sent_bytes, 0);
}
