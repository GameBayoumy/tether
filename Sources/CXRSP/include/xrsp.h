#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define XRSP_PACKET_HEADER_BYTES 8u
#define XRSP_PACKET_MAX_BYTES 0x40000u
#define XRSP_BUILTIN_HEADER_BYTES 8u
#define XRSP_BUILTIN_SCHEMA_STREAM_VERSION 1u
#define XRSP_TOPIC_COUNT 64u
#define XRSP_TOPIC_PADDING 0u
#define XRSP_TOPIC_BUILTIN 1u
#define XRSP_TOPIC_APPLICATION_MIN 2u
#define XRSP_TOPIC_APPLICATION_MAX 63u

#define XRSP_STREAMING_TOPIC_COMMAND 2u
#define XRSP_STREAMING_TOPIC_POSE 3u
#define XRSP_STREAMING_TOPIC_MESH 4u
#define XRSP_STREAMING_TOPIC_VIDEO 5u
#define XRSP_STREAMING_TOPIC_AUDIO 6u
#define XRSP_STREAMING_TOPIC_HAPTIC 7u
#define XRSP_STREAMING_TOPIC_HANDS 8u
#define XRSP_STREAMING_TOPIC_SKELETON 9u
#define XRSP_STREAMING_TOPIC_SLICE_BASE 10u
#define XRSP_STREAMING_TOPIC_SLICE_COUNT 16u
#define XRSP_STREAMING_TOPIC_AUDIO_CONTROL 26u
#define XRSP_STREAMING_TOPIC_USER_SETTINGS_SYNC 27u
#define XRSP_STREAMING_TOPIC_INPUT_CONTROL 28u
#define XRSP_STREAMING_TOPIC_ASW 29u
#define XRSP_STREAMING_TOPIC_BODY 30u
#define XRSP_STREAMING_TOPIC_RUNTIME_IPC 31u
#define XRSP_STREAMING_TOPIC_CAMERA_STREAM 32u
#define XRSP_STREAMING_TOPIC_LOGGING 33u

#define XRSP_STOCK_CLIENT_FRAME_WIDTH 3616u
#define XRSP_STOCK_CLIENT_FRAME_HEIGHT 1920u
#define XRSP_STOCK_CLIENT_EYE_WIDTH 1808u
#define XRSP_STOCK_CLIENT_SLICE_HEIGHT 384u
#define XRSP_STOCK_CLIENT_SLICE_COUNT 5u
#define XRSP_STOCK_CLIENT_FRAME_DURATION_NS 29502900LL

typedef enum xrsp_result {
    XRSP_SUCCESS = 0,
    XRSP_ERROR_INVALID_ARGUMENT = -1,
    XRSP_ERROR_NO_MEMORY = -2,
    XRSP_ERROR_IO = -3,
    XRSP_ERROR_EOF = -4,
    XRSP_ERROR_PROTOCOL = -5,
    XRSP_ERROR_PACKET_TOO_LARGE = -6,
    XRSP_ERROR_UNSUPPORTED_VERSION = -7,
    XRSP_ERROR_INTERRUPTED = -8,
} xrsp_result;

typedef enum xrsp_builtin_type {
    XRSP_BUILTIN_PAIRING_ACK = 0,
    XRSP_BUILTIN_INVITE = 1,
    XRSP_BUILTIN_OK = 2,
    XRSP_BUILTIN_ACK = 3,
    XRSP_BUILTIN_ERROR = 4,
    XRSP_BUILTIN_BYE = 5,
    XRSP_BUILTIN_ECHO = 6,
    XRSP_BUILTIN_PAIRING = 7,
    XRSP_BUILTIN_UNKNOWN_8 = 8,
    XRSP_BUILTIN_CODE_GENERATION = 9,
    XRSP_BUILTIN_CODE_GENERATION_ACK = 10,
    XRSP_BUILTIN_PROCESS_RECOVERED = 11,
    XRSP_BUILTIN_RESERVED = 15,
} xrsp_builtin_type;

typedef enum xrsp_session_type {
    XRSP_SESSION_NONE = 0,
    XRSP_SESSION_BASIC = 1,
    XRSP_SESSION_BENCHMARK = 2,
    XRSP_SESSION_STREAMING = 3,
    XRSP_SESSION_XRSP_TESTER = 4,
} xrsp_session_type;

/*
 * Transport callbacks return the number of bytes transferred, zero for EOF,
 * XRSP_IO_RETRY for a transient condition, or another negative value for an
 * implementation-defined transport error.
 */
#define XRSP_IO_RETRY ((ptrdiff_t)-2)
typedef ptrdiff_t (*xrsp_read_fn)(void *user, void *data, size_t bytes);
typedef ptrdiff_t (*xrsp_write_fn)(void *user, const void *data, size_t bytes);

typedef struct xrsp_io {
    void *user;
    xrsp_read_fn read;
    xrsp_write_fn write;
} xrsp_io;

typedef struct xrsp_config {
    uint8_t packet_version;
    uint8_t minimum_packet_version;
    bool internal_version;
    bool secure_packets;

    /*
     * When non-zero, each outbound write is extended to this byte alignment
     * using a valid topic-0 packet. USB transports commonly require 0x400.
     */
    size_t write_alignment;

    /*
     * Maximum application payload per packet. Zero selects the protocol
     * maximum. Smaller values are useful for transports with limited queues.
     */
    size_t max_payload_bytes;
} xrsp_config;

typedef struct xrsp_connection xrsp_connection;

typedef struct xrsp_packet {
    uint8_t topic;
    uint8_t version;
    bool internal_version;
    bool secure;
    uint16_t sequence;
    uint8_t *payload;
    size_t payload_bytes;
} xrsp_packet;

typedef struct xrsp_builtin_message {
    xrsp_builtin_type type;
    uint16_t status;
    uint32_t schema_stream_version;
    const uint8_t *capnp_payload;
    size_t capnp_payload_bytes;
} xrsp_builtin_message;

typedef struct xrsp_span {
    const void *data;
    size_t bytes;
} xrsp_span;

typedef struct xrsp_handshake {
    xrsp_session_type session_type;
    uint64_t session_id;
    uint16_t *features;
    size_t feature_count;
} xrsp_handshake;

typedef struct xrsp_encoded_slice {
    uint32_t frame_id;
    uint32_t frame_data_04;
    uint32_t frame_data_08;
    float orientation[4];
    float translation[3];
    int64_t frame_timestamp_ns;
    uint8_t slice_index;
    uint8_t slice_flags;
    uint32_t slice_y;
    uint32_t slice_data_38;
    uint32_t payload0_bytes;
    uint32_t payload1_bytes;
    uint32_t slice_data_44;
    int64_t slice_timestamp_ns;
    int64_t slice_duration_ns;
    int64_t frame_timing_0_ns;
    int64_t frame_timing_1_ns;
    int64_t frame_timing_2_ns;
    float fov[2][4];
} xrsp_encoded_slice;

typedef struct xrsp_stock_client_slice {
    xrsp_span codec_config;
    xrsp_span video;
} xrsp_stock_client_slice;

void xrsp_config_init(xrsp_config *config);
const char *xrsp_result_string(xrsp_result result);
const char *xrsp_builtin_type_string(xrsp_builtin_type type);

xrsp_result xrsp_connection_create(const xrsp_io *io,
                                   const xrsp_config *config,
                                   xrsp_connection **out_connection);
void xrsp_connection_destroy(xrsp_connection *connection);
xrsp_result xrsp_connection_interrupt(xrsp_connection *connection);
xrsp_result xrsp_connection_set_topic_secure(xrsp_connection *connection,
                                             uint8_t topic,
                                             bool secure);

xrsp_result xrsp_send_packet(xrsp_connection *connection,
                             uint8_t topic,
                             const void *payload,
                             size_t payload_bytes);
xrsp_result xrsp_receive_packet(xrsp_connection *connection, xrsp_packet *out_packet);
void xrsp_packet_release(xrsp_packet *packet);

xrsp_result xrsp_topic_write(xrsp_connection *connection,
                             uint8_t topic,
                             const void *data,
                             size_t bytes);
xrsp_result xrsp_topic_write_message(xrsp_connection *connection,
                                     uint8_t topic,
                                     const void *capnp_message,
                                     size_t capnp_message_bytes,
                                     const xrsp_span *spans,
                                     size_t span_count);

xrsp_result xrsp_builtin_decode(const void *payload,
                                size_t payload_bytes,
                                xrsp_builtin_message *out_message);
xrsp_result xrsp_send_builtin(xrsp_connection *connection,
                              xrsp_builtin_type type,
                              uint16_t status,
                              const void *capnp_payload,
                              size_t capnp_payload_bytes);

xrsp_result xrsp_build_invite_ok(uint64_t session_id,
                                 xrsp_session_type session_type,
                                 const uint16_t *features,
                                 size_t feature_count,
                                 uint8_t **out_payload,
                                 size_t *out_payload_bytes);
xrsp_result xrsp_build_session_envelope(uint64_t session_id,
                                        xrsp_session_type session_type,
                                        uint8_t **out_payload,
                                        size_t *out_payload_bytes);
xrsp_result xrsp_parse_handshake(const void *capnp_payload,
                                 size_t capnp_payload_bytes,
                                 xrsp_handshake *out_handshake);
void xrsp_handshake_release(xrsp_handshake *handshake);

/*
 * Accepts a basic or streaming invite using the hardware-proven stock Quest
 * client feature policy. Streaming sessions advertise features 5, 6, and 7;
 * basic sessions echo the invite's feature list.
 */
xrsp_result xrsp_send_stock_client_invite_ok(xrsp_connection *connection,
                                             const xrsp_handshake *handshake);

xrsp_result xrsp_build_encoded_slice(const xrsp_encoded_slice *slice,
                                     uint8_t **out_payload,
                                     size_t *out_payload_bytes);

/*
 * Sends one encoded slice on its derived streaming topic. The payload length
 * fields are filled from payload0/payload1, and the capture-proven Cap'n Proto
 * segment-table, segment, and raw-span write boundaries are preserved.
 */
xrsp_result xrsp_send_encoded_slice(xrsp_connection *connection,
                                    const xrsp_encoded_slice *slice,
                                    const void *payload0,
                                    size_t payload0_bytes,
                                    const void *payload1,
                                    size_t payload1_bytes);

/*
 * Sends the hardware-proven five-slice stock Quest client frame profile on
 * topics 10..14. All five slices are serialized as one outbound operation.
 */
xrsp_result xrsp_send_stock_client_frame(
    xrsp_connection *connection,
    uint32_t frame_id,
    int64_t timestamp_ns,
    const xrsp_stock_client_slice slices[XRSP_STOCK_CLIENT_SLICE_COUNT]);

void xrsp_free(void *memory);

#ifdef __cplusplus
}
#endif
