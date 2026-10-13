#ifndef TETHER_DIRECT_H
#define TETHER_DIRECT_H

#include <stdbool.h>
#include <stdint.h>

#include "tether_xr_shared.h"

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Exported by libTetherOpenXR.dylib, next to the OpenXR entry points, for engine plugins that drive the
 * headset themselves. Find the library through the "library_path" of
 * ~/Library/Application Support/Tether/openxr_runtime.json, which Tether keeps current.
 *
 * Tracking space: Tether's (OpenXR conventions: +Y up, -Z forward, metres). Render each eye with
 * state.fov_tangents and state.ipd, then submit the frame with the head pose it was rendered for.
 */

/* Latest tracking; false when Tether isn't running or hasn't published for a while. */
bool tether_direct_read_state(tether_xr_state *out_state);

/* Starts a frame submitter on the engine's command queue (id<MTLCommandQueue>). NULL on failure. */
void *tether_direct_create(void *metal_command_queue);

/*
 * Submits one frame. `metal_texture` (id<MTLTexture>, 2D) holds both eyes; `left_rect` and `right_rect` are
 * { x, y, width, height } in pixels. Call once the frame's rendering is encoded on the same command queue.
 */
bool tether_direct_submit(void *submitter, void *metal_texture, const int32_t left_rect[4],
                          const int32_t right_rect[4], const qlh_pose *render_pose);

void tether_direct_destroy(void *submitter);

#ifdef __cplusplus
}
#endif

#endif
