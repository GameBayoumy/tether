#ifndef TETHER_XR_SHARED_H
#define TETHER_XR_SHARED_H

/*
 * Contract between the Tether app (which owns the USB Link session) and the Tether OpenXR runtime
 * (loaded into Unity / Unreal). The app publishes tracking into a small memory-mapped file; the
 * runtime renders, encodes and sends finished frames back over a Unix-domain socket.
 *
 * Files live in ~/Library/Application Support/Tether/: "xr-state" and "xr.sock".
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include "link_host.h"

#define TETHER_XR_STATE_MAGIC 0x31525854u /* "TXR1" */
#define TETHER_XR_FRAME_MAGIC 0x46525854u /* "TXRF" */
#define TETHER_XR_VERSION 1u

typedef struct tether_xr_state {
    uint32_t magic;
    uint32_t version;
    uint32_t sequence;           /* seqlock: odd while the app is writing (atomic builtins) */
    uint32_t streaming;          /* 1 while the headset is in a Link session */
    uint64_t heartbeat_ns;       /* CLOCK_MONOTONIC ns of the last write */
    qlh_pose head;               /* latest head pose, tracking space */
    qlh_controller controllers[2];
    float ipd;                   /* metres */
    float fov_tangents[2][4];    /* per eye: left, right, up, down (positive tangents) */
    uint32_t eye_width;          /* per-eye pixels the headset frame carries */
    uint32_t eye_height;
    float refresh_hz;
    float floor_height;          /* metres from the tracking origin down to the floor */
    uint32_t recenter_count;     /* bumps when the user recenters (hold Meta); runtime re-anchors LOCAL */
} tether_xr_state;

/* One finished frame from the runtime: header, then each slice's codec config then video bytes. */
typedef struct tether_xr_frame_header {
    uint32_t magic;
    uint32_t frame_id;
    qlh_pose pose;               /* head pose the frame was rendered for */
    uint32_t codec_config_bytes[QLH_SLICE_COUNT];
    uint32_t video_bytes[QLH_SLICE_COUNT];
} tether_xr_frame_header;

static inline void
tether_xr_write_state(tether_xr_state *shared, const tether_xr_state *value)
{
    const size_t body = offsetof(tether_xr_state, streaming);
    uint32_t sequence = __atomic_load_n(&shared->sequence, __ATOMIC_RELAXED);
    __atomic_store_n(&shared->sequence, sequence + 1, __ATOMIC_RELAXED); /* odd: writing */
    __atomic_thread_fence(__ATOMIC_RELEASE);
    shared->magic = value->magic;
    shared->version = value->version;
    memcpy((char *)shared + body, (const char *)value + body, sizeof(*shared) - body);
    __atomic_store_n(&shared->sequence, sequence + 2, __ATOMIC_RELEASE); /* even: done */
}

/* Returns false if no consistent snapshot could be taken (writer busy) or the file isn't initialised. */
static inline bool
tether_xr_read_state(const tether_xr_state *shared, tether_xr_state *out)
{
    for (int attempt = 0; attempt < 8; attempt++) {
        uint32_t before = __atomic_load_n(&shared->sequence, __ATOMIC_ACQUIRE);
        if (before & 1u) {
            continue;
        }
        memcpy(out, (const void *)shared, sizeof(*out));
        __atomic_thread_fence(__ATOMIC_ACQUIRE);
        uint32_t after = __atomic_load_n(&shared->sequence, __ATOMIC_RELAXED);
        if (before == after) {
            return out->magic == TETHER_XR_STATE_MAGIC && out->version == TETHER_XR_VERSION;
        }
    }
    return false;
}

#endif
