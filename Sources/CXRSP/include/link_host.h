#ifndef TETHER_HOST_H
#define TETHER_HOST_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * The PC side of native Quest Link over USB: finds the headset, pairs with its
 * built-in xrspd service, accepts the streaming session the user starts from
 * the headset, decodes head poses and sends encoded video slices.
 */

typedef enum qlh_state {
    QLH_STATE_STOPPED = 0,
    /* No Meta headset with an XRSP interface on USB. */
    QLH_STATE_WAITING_FOR_DEVICE,
    /* Resetting USB and running the pairing handshake. */
    QLH_STATE_CONNECTING,
    /* Paired; the headset offers "Launch" for Quest Link. */
    QLH_STATE_HOST_CONNECTED,
    /* The headset's streaming client accepted a session; frames can be sent. */
    QLH_STATE_STREAMING,
} qlh_state;

typedef struct qlh_pose {
    float orientation[4]; /* x, y, z, w; OVR tracking space (+Y up, -Z forward) */
    float position[3];    /* metres */
    int64_t timestamp_ns; /* headset clock */
} qlh_pose;

/* Touch controller state, merged from the pose topic (pose) and the input topic (buttons, axes). */
typedef struct qlh_controller {
    bool valid;
    bool right;
    uint8_t battery;     /* percent */
    uint32_t buttons;    /* QLH_BTN_* */
    uint32_t touches;    /* capacitive sensors */
    float trigger;       /* 0...1 */
    float grip;          /* 0...1 */
    float stick_x;       /* -1...1 */
    float stick_y;       /* -1...1, up is positive */
    bool pose_valid;
    qlh_pose pose;       /* grip pose, same space as the head */
} qlh_controller;

#define QLH_BTN_A 0x00000001u
#define QLH_BTN_B 0x00000002u
#define QLH_BTN_STICK_R 0x00000004u
#define QLH_BTN_X 0x00000100u
#define QLH_BTN_Y 0x00000200u
#define QLH_BTN_STICK_L 0x00000400u
#define QLH_BTN_SYSTEM 0x01000000u
#define QLH_BTN_MENU 0x40000000u

typedef struct qlh_fov {
    float up, down, left, right; /* degrees, all positive */
} qlh_fov;

typedef struct qlh_headset_info {
    uint32_t display_width;  /* both eyes */
    uint32_t display_height;
    float refresh_hz;
    qlh_fov eye_fov[2];
    bool valid;
} qlh_headset_info;

/* Width/height of the frame layout the stock streaming client accepts. */
#define QLH_FRAME_WIDTH 3616u
#define QLH_FRAME_HEIGHT 1920u
#define QLH_SLICE_HEIGHT 384u
#define QLH_SLICE_COUNT 5u

typedef struct qlh_slice {
    const void *codec_config; /* Annex-B SPS+PPS, only on keyframes */
    size_t codec_config_bytes;
    const void *video;        /* Annex-B slice data */
    size_t video_bytes;
} qlh_slice;

typedef struct qlh_host qlh_host;

/* Called whenever the state changes: from the host thread, or from the caller of qlh_end_streaming. */
typedef void (*qlh_state_callback)(void *user, qlh_state state, const char *detail);

qlh_host *qlh_create(qlh_state_callback callback, void *user);
void qlh_destroy(qlh_host *host);

/* Starts the background thread. It retries automatically when the headset is unplugged. */
bool qlh_start(qlh_host *host);
void qlh_stop(qlh_host *host);

qlh_state qlh_get_state(const qlh_host *host);

/* Latest head pose; returns false until one has been received this session. */
bool qlh_get_pose(qlh_host *host, qlh_pose *out_pose, uint64_t *out_pose_count);

/* Left [0] and right [1] controllers. Returns false until any controller data has arrived. */
bool qlh_get_controllers(qlh_host *host, qlh_controller out_controllers[2]);

/* Interpupillary distance reported by the headset, in metres (0 until known). */
float qlh_get_ipd(qlh_host *host);

/* Lens and display description from the streaming invite. */
bool qlh_get_headset_info(qlh_host *host, qlh_headset_info *out_info);

/*
 * Field-of-view tangents declared in every slice, per eye: the frustum the frame was rendered with.
 * The headset unprojects each eye with these, so they must match the renderer exactly.
 */
void qlh_set_frame_fov(qlh_host *host, const float tangents[2][4]);

/* Sends one frame as QLH_SLICE_COUNT slices rendered for `pose`. Thread-safe. */
bool qlh_send_frame(qlh_host *host, uint32_t frame_id, const qlh_pose *pose,
                    const qlh_slice slices[QLH_SLICE_COUNT]);

/* Ends the streaming session (like quitting Link in Meta's PC app); the headset returns to Quest Home. */
bool qlh_end_streaming(qlh_host *host);

/* Bytes of video sent since the previous call. */
uint64_t qlh_take_sent_bytes(qlh_host *host);

#ifdef __cplusplus
}
#endif

#endif
