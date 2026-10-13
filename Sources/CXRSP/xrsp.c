#include "xrsp.h"

#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

struct xrsp_connection {
    xrsp_io io;
    xrsp_config config;
    uint16_t sequence[XRSP_TOPIC_COUNT];
    bool topic_secure[XRSP_TOPIC_COUNT];
    atomic_flag write_lock;
    atomic_bool interrupted;
};

static uint16_t
read_u16le(const uint8_t *p)
{
    return (uint16_t)p[0] | ((uint16_t)p[1] << 8);
}

static uint32_t
read_u32le(const uint8_t *p)
{
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) |
           ((uint32_t)p[3] << 24);
}

static uint64_t
read_u64le(const uint8_t *p)
{
    return (uint64_t)read_u32le(p) | ((uint64_t)read_u32le(p + 4) << 32);
}

static void
write_u16le(uint8_t *p, uint16_t value)
{
    p[0] = (uint8_t)value;
    p[1] = (uint8_t)(value >> 8);
}

static void
write_u32le(uint8_t *p, uint32_t value)
{
    p[0] = (uint8_t)value;
    p[1] = (uint8_t)(value >> 8);
    p[2] = (uint8_t)(value >> 16);
    p[3] = (uint8_t)(value >> 24);
}

static void
write_u64le(uint8_t *p, uint64_t value)
{
    write_u32le(p, (uint32_t)value);
    write_u32le(p + 4, (uint32_t)(value >> 32));
}

static void
write_f32le(uint8_t *p, float value)
{
    uint32_t bits;
    memcpy(&bits, &value, sizeof(bits));
    write_u32le(p, bits);
}

static xrsp_result
read_exact(xrsp_connection *connection, void *data, size_t bytes)
{
    uint8_t *out = data;
    size_t offset = 0;

    while (offset < bytes) {
        if (atomic_load_explicit(&connection->interrupted, memory_order_acquire)) {
            return XRSP_ERROR_INTERRUPTED;
        }
        ptrdiff_t result = connection->io.read(connection->io.user, out + offset, bytes - offset);
        if (result == XRSP_IO_RETRY) {
            continue;
        }
        if (result < 0) {
            return XRSP_ERROR_IO;
        }
        if (result == 0) {
            return XRSP_ERROR_EOF;
        }
        if ((size_t)result > bytes - offset) {
            return XRSP_ERROR_IO;
        }
        offset += (size_t)result;
    }
    return XRSP_SUCCESS;
}

static xrsp_result
write_exact(xrsp_connection *connection, const void *data, size_t bytes)
{
    const uint8_t *in = data;
    size_t offset = 0;

    while (offset < bytes) {
        if (atomic_load_explicit(&connection->interrupted, memory_order_acquire)) {
            return XRSP_ERROR_INTERRUPTED;
        }
        ptrdiff_t result = connection->io.write(connection->io.user, in + offset, bytes - offset);
        if (result == XRSP_IO_RETRY) {
            continue;
        }
        if (result <= 0 || (size_t)result > bytes - offset) {
            return XRSP_ERROR_IO;
        }
        offset += (size_t)result;
    }
    return XRSP_SUCCESS;
}

static void
lock_writes(xrsp_connection *connection)
{
    while (atomic_flag_test_and_set_explicit(&connection->write_lock, memory_order_acquire)) {
    }
}

static void
unlock_writes(xrsp_connection *connection)
{
    atomic_flag_clear_explicit(&connection->write_lock, memory_order_release);
}

static xrsp_result
make_packet(xrsp_connection *connection,
            uint8_t topic,
            const void *payload,
            size_t payload_bytes,
            uint8_t **out_packet,
            size_t *out_packet_bytes)
{
    size_t total_without_padding;
    size_t padding_bytes;
    size_t total_bytes;
    uint16_t flags;
    uint8_t *packet;

    if (topic >= XRSP_TOPIC_COUNT || out_packet == NULL || out_packet_bytes == NULL) {
        return XRSP_ERROR_INVALID_ARGUMENT;
    }
    if (payload_bytes > XRSP_PACKET_MAX_BYTES - XRSP_PACKET_HEADER_BYTES) {
        return XRSP_ERROR_PACKET_TOO_LARGE;
    }

    total_without_padding = XRSP_PACKET_HEADER_BYTES + payload_bytes;
    padding_bytes = (4u - (total_without_padding & 3u)) & 3u;
    total_bytes = total_without_padding + padding_bytes;
    if (total_bytes > XRSP_PACKET_MAX_BYTES) {
        return XRSP_ERROR_PACKET_TOO_LARGE;
    }

    packet = calloc(1, total_bytes);
    if (packet == NULL) {
        return XRSP_ERROR_NO_MEMORY;
    }

    flags = (uint16_t)(((uint16_t)connection->config.packet_version & 7u) << 5);
    flags |= (uint16_t)((connection->config.internal_version ? 1u : 0u) << 4);
    flags |= (uint16_t)((connection->topic_secure[topic] ? 1u : 0u) << 2);
    flags |= (uint16_t)((uint16_t)topic << 8);
    if (padding_bytes != 0) {
        flags |= (uint16_t)(1u << 3);
        packet[total_bytes - 1] = (uint8_t)padding_bytes;
    }

    write_u16le(packet, flags);
    write_u16le(packet + 2, (uint16_t)(total_bytes / 4u - 1u));
    write_u16le(packet + 4, connection->sequence[topic]++);
    write_u16le(packet + 6, 0);
    if (payload_bytes != 0 && payload != NULL) {
        memcpy(packet + XRSP_PACKET_HEADER_BYTES, payload, payload_bytes);
    }

    *out_packet = packet;
    *out_packet_bytes = total_bytes;
    return XRSP_SUCCESS;
}

void
xrsp_config_init(xrsp_config *config)
{
    if (config == NULL) {
        return;
    }
    memset(config, 0, sizeof(*config));
    config->internal_version = true;
    config->max_payload_bytes = XRSP_PACKET_MAX_BYTES - XRSP_PACKET_HEADER_BYTES;
}

const char *
xrsp_result_string(xrsp_result result)
{
    switch (result) {
    case XRSP_SUCCESS:
        return "success";
    case XRSP_ERROR_INVALID_ARGUMENT:
        return "invalid argument";
    case XRSP_ERROR_NO_MEMORY:
        return "out of memory";
    case XRSP_ERROR_IO:
        return "transport I/O error";
    case XRSP_ERROR_EOF:
        return "transport closed";
    case XRSP_ERROR_PROTOCOL:
        return "protocol error";
    case XRSP_ERROR_PACKET_TOO_LARGE:
        return "packet too large";
    case XRSP_ERROR_UNSUPPORTED_VERSION:
        return "unsupported packet version";
    case XRSP_ERROR_INTERRUPTED:
        return "connection interrupted";
    default:
        return "unknown XRSP error";
    }
}

const char *
xrsp_builtin_type_string(xrsp_builtin_type type)
{
    switch (type) {
    case XRSP_BUILTIN_PAIRING_ACK:
        return "PAIRING_ACK";
    case XRSP_BUILTIN_INVITE:
        return "INVITE";
    case XRSP_BUILTIN_OK:
        return "OK";
    case XRSP_BUILTIN_ACK:
        return "ACK";
    case XRSP_BUILTIN_ERROR:
        return "ERROR";
    case XRSP_BUILTIN_BYE:
        return "BYE";
    case XRSP_BUILTIN_ECHO:
        return "ECHO";
    case XRSP_BUILTIN_PAIRING:
        return "PAIRING";
    case XRSP_BUILTIN_CODE_GENERATION:
        return "CODE_GENERATION";
    case XRSP_BUILTIN_CODE_GENERATION_ACK:
        return "CODE_GENERATION_ACK";
    case XRSP_BUILTIN_PROCESS_RECOVERED:
        return "PROCESS_RECOVERED";
    case XRSP_BUILTIN_RESERVED:
        return "RESERVED";
    default:
        return "UNKNOWN";
    }
}

xrsp_result
xrsp_connection_create(const xrsp_io *io,
                       const xrsp_config *config,
                       xrsp_connection **out_connection)
{
    xrsp_connection *connection;
    xrsp_config selected;

    if (io == NULL || io->read == NULL || io->write == NULL || out_connection == NULL) {
        return XRSP_ERROR_INVALID_ARGUMENT;
    }
    xrsp_config_init(&selected);
    if (config != NULL) {
        selected = *config;
        if (selected.max_payload_bytes == 0) {
            selected.max_payload_bytes = XRSP_PACKET_MAX_BYTES - XRSP_PACKET_HEADER_BYTES;
        }
    }
    if (selected.packet_version > 7 || selected.minimum_packet_version > 7 ||
        selected.minimum_packet_version > selected.packet_version ||
        selected.max_payload_bytes > XRSP_PACKET_MAX_BYTES - XRSP_PACKET_HEADER_BYTES ||
        (selected.write_alignment != 0 &&
         (selected.write_alignment < XRSP_PACKET_HEADER_BYTES ||
          (selected.write_alignment & 3u) != 0))) {
        return XRSP_ERROR_INVALID_ARGUMENT;
    }

    connection = calloc(1, sizeof(*connection));
    if (connection == NULL) {
        return XRSP_ERROR_NO_MEMORY;
    }
    connection->io = *io;
    connection->config = selected;
    for (size_t i = 0; i < XRSP_TOPIC_COUNT; i++) {
        connection->topic_secure[i] = selected.secure_packets;
    }
    atomic_flag_clear(&connection->write_lock);
    atomic_init(&connection->interrupted, false);
    *out_connection = connection;
    return XRSP_SUCCESS;
}

void
xrsp_connection_destroy(xrsp_connection *connection)
{
    free(connection);
}

xrsp_result
xrsp_connection_interrupt(xrsp_connection *connection)
{
    if (connection == NULL) {
        return XRSP_ERROR_INVALID_ARGUMENT;
    }
    atomic_store_explicit(&connection->interrupted, true, memory_order_release);
    return XRSP_SUCCESS;
}

xrsp_result
xrsp_connection_set_topic_secure(xrsp_connection *connection, uint8_t topic, bool secure)
{
    if (connection == NULL || topic >= XRSP_TOPIC_COUNT) {
        return XRSP_ERROR_INVALID_ARGUMENT;
    }
    lock_writes(connection);
    connection->topic_secure[topic] = secure;
    unlock_writes(connection);
    return XRSP_SUCCESS;
}

xrsp_result
send_packet_unlocked(xrsp_connection *connection,
                     uint8_t topic,
                     const void *payload,
                     size_t payload_bytes)
{
    uint8_t *packet = NULL;
    size_t packet_bytes = 0;
    size_t alignment;
    size_t batch_bytes;
    size_t trailing_bytes;
    uint8_t *padding_packet = NULL;
    size_t padding_packet_bytes = 0;
    uint8_t *batch = NULL;
    xrsp_result result;

    if (connection == NULL || (payload_bytes != 0 && payload == NULL) ||
        payload_bytes > connection->config.max_payload_bytes) {
        return connection == NULL ? XRSP_ERROR_INVALID_ARGUMENT : XRSP_ERROR_PACKET_TOO_LARGE;
    }

    result = make_packet(connection, topic, payload, payload_bytes, &packet, &packet_bytes);
    if (result != XRSP_SUCCESS) {
        return result;
    }

    alignment = connection->config.write_alignment;
    if (alignment == 0 || packet_bytes % alignment == 0) {
        result = write_exact(connection, packet, packet_bytes);
        free(packet);
        return result;
    }

    trailing_bytes = alignment - (packet_bytes % alignment);
    if (trailing_bytes < XRSP_PACKET_HEADER_BYTES) {
        trailing_bytes += alignment;
    }
    result = make_packet(connection,
                         XRSP_TOPIC_PADDING,
                         NULL,
                         trailing_bytes - XRSP_PACKET_HEADER_BYTES,
                         &padding_packet,
                         &padding_packet_bytes);
    if (result != XRSP_SUCCESS) {
        free(packet);
        return result;
    }
    if (padding_packet_bytes != trailing_bytes) {
        free(packet);
        free(padding_packet);
        return XRSP_ERROR_PROTOCOL;
    }

    batch_bytes = packet_bytes + padding_packet_bytes;
    batch = malloc(batch_bytes);
    if (batch == NULL) {
        free(packet);
        free(padding_packet);
        return XRSP_ERROR_NO_MEMORY;
    }
    memcpy(batch, packet, packet_bytes);
    memcpy(batch + packet_bytes, padding_packet, padding_packet_bytes);
    result = write_exact(connection, batch, batch_bytes);
    free(batch);
    free(padding_packet);
    free(packet);
    return result;
}

xrsp_result
xrsp_send_packet(xrsp_connection *connection,
                 uint8_t topic,
                 const void *payload,
                 size_t payload_bytes)
{
    xrsp_result result;

    if (connection == NULL) {
        return XRSP_ERROR_INVALID_ARGUMENT;
    }
    lock_writes(connection);
    result = send_packet_unlocked(connection, topic, payload, payload_bytes);
    unlock_writes(connection);
    return result;
}

xrsp_result
xrsp_receive_packet(xrsp_connection *connection, xrsp_packet *out_packet)
{
    uint8_t header[XRSP_PACKET_HEADER_BYTES];
    uint16_t flags;
    uint16_t total_words_minus_one;
    size_t total_bytes;
    size_t payload_capacity;
    size_t padding_bytes = 0;
    uint8_t *payload = NULL;
    xrsp_result result;

    if (connection == NULL || out_packet == NULL) {
        return XRSP_ERROR_INVALID_ARGUMENT;
    }
    memset(out_packet, 0, sizeof(*out_packet));

    result = read_exact(connection, header, sizeof(header));
    if (result != XRSP_SUCCESS) {
        return result;
    }
    flags = read_u16le(header);
    total_words_minus_one = read_u16le(header + 2);
    total_bytes = ((size_t)total_words_minus_one + 1u) * 4u;
    if (total_words_minus_one == 0 || total_bytes > XRSP_PACKET_MAX_BYTES) {
        return XRSP_ERROR_PROTOCOL;
    }

    out_packet->topic = (uint8_t)((flags >> 8) & 0x3fu);
    out_packet->version = (uint8_t)((flags >> 5) & 7u);
    out_packet->internal_version = ((flags >> 4) & 1u) != 0;
    out_packet->secure = ((flags >> 2) & 1u) != 0;
    out_packet->sequence = read_u16le(header + 4);

    if (out_packet->version < connection->config.minimum_packet_version ||
        out_packet->internal_version != connection->config.internal_version) {
        return XRSP_ERROR_UNSUPPORTED_VERSION;
    }

    payload_capacity = total_bytes - XRSP_PACKET_HEADER_BYTES;
    if (payload_capacity != 0) {
        payload = malloc(payload_capacity);
        if (payload == NULL) {
            return XRSP_ERROR_NO_MEMORY;
        }
        result = read_exact(connection, payload, payload_capacity);
        if (result != XRSP_SUCCESS) {
            free(payload);
            return result;
        }
    }

    if ((flags & (1u << 3)) != 0) {
        if (payload_capacity == 0) {
            free(payload);
            return XRSP_ERROR_PROTOCOL;
        }
        padding_bytes = payload[payload_capacity - 1];
        if (padding_bytes == 0 || padding_bytes > payload_capacity) {
            free(payload);
            return XRSP_ERROR_PROTOCOL;
        }
    }

    out_packet->payload = payload;
    out_packet->payload_bytes = payload_capacity - padding_bytes;
    return XRSP_SUCCESS;
}

void
xrsp_packet_release(xrsp_packet *packet)
{
    if (packet == NULL) {
        return;
    }
    free(packet->payload);
    memset(packet, 0, sizeof(*packet));
}

xrsp_result
topic_write_unlocked(xrsp_connection *connection, uint8_t topic, const void *data, size_t bytes)
{
    const uint8_t *input = data;
    size_t offset = 0;
    size_t chunk_bytes;
    xrsp_result result;

    if (connection == NULL || topic < XRSP_TOPIC_APPLICATION_MIN ||
        topic > XRSP_TOPIC_APPLICATION_MAX || (bytes != 0 && data == NULL)) {
        return XRSP_ERROR_INVALID_ARGUMENT;
    }
    while (offset < bytes) {
        chunk_bytes = bytes - offset;
        if (chunk_bytes > connection->config.max_payload_bytes) {
            chunk_bytes = connection->config.max_payload_bytes;
        }
        result = send_packet_unlocked(connection, topic, input + offset, chunk_bytes);
        if (result != XRSP_SUCCESS) {
            return result;
        }
        offset += chunk_bytes;
    }
    return XRSP_SUCCESS;
}

xrsp_result
xrsp_topic_write(xrsp_connection *connection, uint8_t topic, const void *data, size_t bytes)
{
    xrsp_result result;

    if (connection == NULL) {
        return XRSP_ERROR_INVALID_ARGUMENT;
    }
    lock_writes(connection);
    result = topic_write_unlocked(connection, topic, data, bytes);
    unlock_writes(connection);
    return result;
}

xrsp_result
xrsp_topic_write_message(xrsp_connection *connection,
                         uint8_t topic,
                         const void *capnp_message,
                         size_t capnp_message_bytes,
                         const xrsp_span *spans,
                         size_t span_count)
{
    size_t i;
    xrsp_result result;

    if ((capnp_message_bytes != 0 && capnp_message == NULL) ||
        (span_count != 0 && spans == NULL)) {
        return XRSP_ERROR_INVALID_ARGUMENT;
    }
    if (connection == NULL) {
        return XRSP_ERROR_INVALID_ARGUMENT;
    }
    lock_writes(connection);
    result = topic_write_unlocked(connection, topic, capnp_message, capnp_message_bytes);
    if (result != XRSP_SUCCESS) {
        unlock_writes(connection);
        return result;
    }
    for (i = 0; i < span_count; i++) {
        result = topic_write_unlocked(connection, topic, spans[i].data, spans[i].bytes);
        if (result != XRSP_SUCCESS) {
            unlock_writes(connection);
            return result;
        }
    }
    unlock_writes(connection);
    return XRSP_SUCCESS;
}

xrsp_result
xrsp_builtin_decode(const void *payload, size_t payload_bytes, xrsp_builtin_message *out_message)
{
    const uint8_t *bytes = payload;
    uint32_t word0;
    size_t encoded_bytes;

    if (payload == NULL || out_message == NULL || payload_bytes < XRSP_BUILTIN_HEADER_BYTES) {
        return XRSP_ERROR_INVALID_ARGUMENT;
    }
    word0 = read_u32le(bytes);
    encoded_bytes = (size_t)((word0 >> 12) & 0xffffcu);
    if (encoded_bytes < XRSP_BUILTIN_HEADER_BYTES || encoded_bytes != payload_bytes) {
        return XRSP_ERROR_PROTOCOL;
    }

    out_message->type = (xrsp_builtin_type)(word0 & 0xfu);
    out_message->status = (uint16_t)((word0 >> 4) & 0x1ffu);
    out_message->schema_stream_version = read_u32le(bytes + 4);
    if (out_message->schema_stream_version != XRSP_BUILTIN_SCHEMA_STREAM_VERSION) {
        return XRSP_ERROR_PROTOCOL;
    }
    out_message->capnp_payload = bytes + XRSP_BUILTIN_HEADER_BYTES;
    out_message->capnp_payload_bytes = payload_bytes - XRSP_BUILTIN_HEADER_BYTES;
    return XRSP_SUCCESS;
}

xrsp_result
xrsp_send_builtin(xrsp_connection *connection,
                  xrsp_builtin_type type,
                  uint16_t status,
                  const void *capnp_payload,
                  size_t capnp_payload_bytes)
{
    uint8_t *payload;
    size_t payload_bytes;
    uint32_t word0;
    xrsp_result result;

    if (connection == NULL || (capnp_payload_bytes != 0 && capnp_payload == NULL) ||
        capnp_payload_bytes > XRSP_PACKET_MAX_BYTES - XRSP_PACKET_HEADER_BYTES -
                                  XRSP_BUILTIN_HEADER_BYTES) {
        return XRSP_ERROR_INVALID_ARGUMENT;
    }
    payload_bytes = XRSP_BUILTIN_HEADER_BYTES + capnp_payload_bytes;
    payload = malloc(payload_bytes);
    if (payload == NULL) {
        return XRSP_ERROR_NO_MEMORY;
    }
    word0 = ((uint32_t)type & 0xfu) | (((uint32_t)status & 0x1ffu) << 4);
    word0 |= (uint32_t)((capnp_payload_bytes * 0x1000u + 0xb000u) & 0xffffc000u);
    write_u32le(payload, word0);
    write_u32le(payload + 4, XRSP_BUILTIN_SCHEMA_STREAM_VERSION);
    if (capnp_payload_bytes != 0) {
        memcpy(payload + XRSP_BUILTIN_HEADER_BYTES, capnp_payload, capnp_payload_bytes);
    }
    result = xrsp_send_packet(connection, XRSP_TOPIC_BUILTIN, payload, payload_bytes);
    free(payload);
    return result;
}

static uint64_t
capnp_struct_pointer(int32_t offset_words, uint16_t data_words, uint16_t pointer_count)
{
    return ((uint64_t)((uint32_t)offset_words & 0x3fffffffu) << 2) |
           ((uint64_t)data_words << 32) | ((uint64_t)pointer_count << 48);
}

static uint64_t
capnp_list_pointer(int32_t offset_words, uint8_t element_size, uint32_t element_count)
{
    return 1u | ((uint64_t)((uint32_t)offset_words & 0x3fffffffu) << 2) |
           ((uint64_t)element_size << 32) | ((uint64_t)element_count << 35);
}

static xrsp_result
allocate_single_segment(size_t segment_words,
                        uint8_t **out_payload,
                        size_t *out_payload_bytes,
                        uint8_t **out_segment)
{
    uint8_t *payload;
    size_t bytes;

    if (out_payload == NULL || out_payload_bytes == NULL || out_segment == NULL ||
        segment_words > UINT32_MAX || segment_words > (SIZE_MAX - 8u) / 8u) {
        return XRSP_ERROR_INVALID_ARGUMENT;
    }
    bytes = 8u + segment_words * 8u;
    payload = calloc(1, bytes);
    if (payload == NULL) {
        return XRSP_ERROR_NO_MEMORY;
    }
    write_u32le(payload, 0);
    write_u32le(payload + 4, (uint32_t)segment_words);
    *out_payload = payload;
    *out_payload_bytes = bytes;
    *out_segment = payload + 8;
    return XRSP_SUCCESS;
}

xrsp_result
xrsp_build_invite_ok(uint64_t session_id,
                     xrsp_session_type session_type,
                     const uint16_t *features,
                     size_t feature_count,
                     uint8_t **out_payload,
                     size_t *out_payload_bytes)
{
    const size_t data_words = 15;
    const size_t pointer_count = 4;
    size_t list_words;
    size_t segment_words;
    size_t pointer_base;
    size_t list_word_index;
    uint8_t *segment;
    size_t i;
    xrsp_result result;

    if ((feature_count != 0 && features == NULL) || feature_count > UINT32_MAX) {
        return XRSP_ERROR_INVALID_ARGUMENT;
    }
    list_words = (feature_count * 2u + 7u) / 8u;
    segment_words = 1u + data_words + pointer_count + list_words;
    result = allocate_single_segment(segment_words, out_payload, out_payload_bytes, &segment);
    if (result != XRSP_SUCCESS) {
        return result;
    }

    write_u64le(segment, capnp_struct_pointer(0, (uint16_t)data_words, (uint16_t)pointer_count));
    write_u64le(segment + 8, (uint64_t)session_type);
    write_u64le(segment + 8u + 10u * 8u, session_id);
    pointer_base = 1u + data_words;
    list_word_index = pointer_base + pointer_count;
    write_u64le(segment + (pointer_base + 1u) * 8u,
                capnp_list_pointer((int32_t)(list_word_index - (pointer_base + 2u)),
                                   3,
                                   (uint32_t)feature_count));
    for (i = 0; i < feature_count; i++) {
        write_u16le(segment + list_word_index * 8u + i * 2u, features[i]);
    }
    return XRSP_SUCCESS;
}

xrsp_result
xrsp_build_session_envelope(uint64_t session_id,
                            xrsp_session_type session_type,
                            uint8_t **out_payload,
                            size_t *out_payload_bytes)
{
    uint8_t *segment;
    xrsp_result result = allocate_single_segment(3, out_payload, out_payload_bytes, &segment);
    if (result != XRSP_SUCCESS) {
        return result;
    }
    write_u64le(segment, capnp_struct_pointer(0, 2, 0));
    write_u64le(segment + 8, (uint64_t)session_type);
    write_u64le(segment + 16, session_id);
    return XRSP_SUCCESS;
}

static int32_t
capnp_signed_offset(uint64_t pointer)
{
    uint32_t offset = (uint32_t)((pointer >> 2) & 0x3fffffffu);
    if ((offset & (1u << 29)) != 0) {
        offset |= 0xc0000000u;
    }
    return (int32_t)offset;
}

xrsp_result
xrsp_parse_handshake(const void *capnp_payload,
                     size_t capnp_payload_bytes,
                     xrsp_handshake *out_handshake)
{
    const uint8_t *payload = capnp_payload;
    const uint8_t *segment;
    size_t segment_bytes;
    uint32_t segment_words;
    uint64_t root;
    int32_t root_offset;
    uint16_t data_words;
    uint16_t pointer_count;
    size_t data_word_index;
    size_t data_bytes;
    size_t pointer_base;
    size_t i;

    if (capnp_payload == NULL || out_handshake == NULL || capnp_payload_bytes < 16) {
        return XRSP_ERROR_INVALID_ARGUMENT;
    }
    memset(out_handshake, 0, sizeof(*out_handshake));
    if (read_u32le(payload) != 0) {
        return XRSP_ERROR_PROTOCOL;
    }
    segment_words = read_u32le(payload + 4);
    segment_bytes = (size_t)segment_words * 8u;
    if (segment_words == 0 || segment_bytes > capnp_payload_bytes - 8u) {
        return XRSP_ERROR_PROTOCOL;
    }
    segment = payload + 8;
    root = read_u64le(segment);
    if ((root & 3u) != 0) {
        return XRSP_ERROR_PROTOCOL;
    }
    root_offset = capnp_signed_offset(root);
    if (root_offset < 0) {
        return XRSP_ERROR_PROTOCOL;
    }
    data_words = (uint16_t)(root >> 32);
    pointer_count = (uint16_t)(root >> 48);
    data_word_index = 1u + (size_t)root_offset;
    data_bytes = (size_t)data_words * 8u;
    if (data_word_index > segment_words || data_bytes > segment_bytes - data_word_index * 8u) {
        return XRSP_ERROR_PROTOCOL;
    }

    out_handshake->session_type = (xrsp_session_type)read_u16le(segment + data_word_index * 8u);
    if (data_words >= 15) {
        out_handshake->session_id = read_u64le(segment + data_word_index * 8u + 0x50u);
    } else if (data_words >= 7) {
        out_handshake->session_id = read_u64le(segment + data_word_index * 8u + 0x30u);
    } else if (data_words >= 2) {
        out_handshake->session_id = read_u64le(segment + data_word_index * 8u + 0x08u);
    }

    pointer_base = data_word_index + data_words;
    if (pointer_base > segment_words || pointer_count > segment_words - pointer_base) {
        return XRSP_ERROR_PROTOCOL;
    }
    for (i = 0; i < pointer_count; i++) {
        uint64_t pointer = read_u64le(segment + (pointer_base + i) * 8u);
        int32_t offset;
        uint8_t element_size;
        uint32_t element_count;
        size_t list_word_index;
        size_t list_bytes;
        size_t j;

        if (pointer == 0 || (pointer & 3u) != 1u) {
            continue;
        }
        offset = capnp_signed_offset(pointer);
        element_size = (uint8_t)((pointer >> 32) & 7u);
        element_count = (uint32_t)((pointer >> 35) & 0x1fffffffu);
        if (element_size != 3 || offset < 0) {
            continue;
        }
        list_word_index = pointer_base + i + 1u + (size_t)offset;
        list_bytes = (size_t)element_count * 2u;
        if (list_word_index > segment_words || list_bytes > segment_bytes - list_word_index * 8u) {
            return XRSP_ERROR_PROTOCOL;
        }
        if (element_count != 0) {
            out_handshake->features = malloc((size_t)element_count * sizeof(uint16_t));
            if (out_handshake->features == NULL) {
                return XRSP_ERROR_NO_MEMORY;
            }
            for (j = 0; j < element_count; j++) {
                out_handshake->features[j] =
                    read_u16le(segment + list_word_index * 8u + j * 2u);
            }
            out_handshake->feature_count = element_count;
        }
        break;
    }
    return XRSP_SUCCESS;
}

void
xrsp_handshake_release(xrsp_handshake *handshake)
{
    if (handshake == NULL) {
        return;
    }
    free(handshake->features);
    memset(handshake, 0, sizeof(*handshake));
}

xrsp_result
xrsp_send_stock_client_invite_ok(xrsp_connection *connection, const xrsp_handshake *handshake)
{
    static const uint16_t streaming_features[] = {5, 6, 7};
    const uint16_t *features;
    size_t feature_count;
    uint8_t *payload = NULL;
    size_t payload_bytes = 0;
    xrsp_result result;

    if (connection == NULL || handshake == NULL ||
        (handshake->feature_count != 0 && handshake->features == NULL) ||
        (handshake->session_type != XRSP_SESSION_BASIC &&
         handshake->session_type != XRSP_SESSION_STREAMING)) {
        return XRSP_ERROR_INVALID_ARGUMENT;
    }
    features = handshake->features;
    feature_count = handshake->feature_count;
    if (handshake->session_type == XRSP_SESSION_STREAMING) {
        features = streaming_features;
        feature_count = sizeof(streaming_features) / sizeof(streaming_features[0]);
    }
    result = xrsp_build_invite_ok(handshake->session_id, handshake->session_type, features,
                                  feature_count, &payload, &payload_bytes);
    if (result != XRSP_SUCCESS) {
        return result;
    }
    result = xrsp_send_builtin(connection, XRSP_BUILTIN_OK, 200, payload, payload_bytes);
    free(payload);
    return result;
}

xrsp_result
xrsp_build_encoded_slice(const xrsp_encoded_slice *slice,
                         uint8_t **out_payload,
                         size_t *out_payload_bytes)
{
    const size_t data_words = 14;
    const size_t pointer_count = 2;
    const size_t segment_words = 1u + data_words + pointer_count + 4u;
    const size_t pointer_base = 1u + data_words;
    const size_t fov0_word = pointer_base + pointer_count;
    const size_t fov1_word = fov0_word + 2u;
    uint8_t *segment;
    uint8_t *data;
    size_t eye;
    size_t value;
    xrsp_result result;

    if (slice == NULL || slice->slice_index >= XRSP_STREAMING_TOPIC_SLICE_COUNT) {
        return XRSP_ERROR_INVALID_ARGUMENT;
    }
    result = allocate_single_segment(segment_words, out_payload, out_payload_bytes, &segment);
    if (result != XRSP_SUCCESS) {
        return result;
    }
    write_u64le(segment, capnp_struct_pointer(0, (uint16_t)data_words, (uint16_t)pointer_count));
    data = segment + 8;

    write_u32le(data + 0x00, slice->frame_id);
    write_u32le(data + 0x04, slice->frame_data_04);
    write_u32le(data + 0x08, slice->frame_data_08);
    for (value = 0; value < 4; value++) {
        write_f32le(data + 0x0c + value * 4u, slice->orientation[value]);
    }
    for (value = 0; value < 3; value++) {
        write_f32le(data + 0x1c + value * 4u, slice->translation[value]);
    }
    write_u64le(data + 0x28, (uint64_t)slice->frame_timestamp_ns);
    data[0x30] = slice->slice_index;
    data[0x31] = slice->slice_flags;
    write_u32le(data + 0x34, slice->slice_y);
    write_u32le(data + 0x38, slice->slice_data_38);
    write_u32le(data + 0x3c, slice->payload0_bytes);
    write_u32le(data + 0x40, slice->payload1_bytes);
    write_u32le(data + 0x44, slice->slice_data_44);
    write_u64le(data + 0x48, (uint64_t)slice->slice_timestamp_ns);
    write_u64le(data + 0x50, (uint64_t)slice->slice_duration_ns);
    write_u64le(data + 0x58, (uint64_t)slice->frame_timing_0_ns);
    write_u64le(data + 0x60, (uint64_t)slice->frame_timing_1_ns);
    write_u64le(data + 0x68, (uint64_t)slice->frame_timing_2_ns);

    write_u64le(segment + pointer_base * 8u,
                capnp_struct_pointer((int32_t)(fov0_word - (pointer_base + 1u)), 2, 0));
    write_u64le(segment + (pointer_base + 1u) * 8u,
                capnp_struct_pointer((int32_t)(fov1_word - (pointer_base + 2u)), 2, 0));
    for (eye = 0; eye < 2; eye++) {
        size_t fov_word = eye == 0 ? fov0_word : fov1_word;
        for (value = 0; value < 4; value++) {
            write_f32le(segment + fov_word * 8u + value * 4u, slice->fov[eye][value]);
        }
    }
    return XRSP_SUCCESS;
}

static xrsp_result
send_encoded_slice_unlocked(xrsp_connection *connection,
                            const xrsp_encoded_slice *slice,
                            const void *payload0,
                            size_t payload0_bytes,
                            const void *payload1,
                            size_t payload1_bytes)
{
    xrsp_encoded_slice encoded;
    uint8_t *capnp = NULL;
    size_t capnp_bytes = 0;
    uint8_t topic;
    xrsp_result result;

    if (slice == NULL || (payload0_bytes != 0 && payload0 == NULL) ||
        (payload1_bytes != 0 && payload1 == NULL) || payload0_bytes > UINT32_MAX ||
        payload1_bytes > UINT32_MAX) {
        return XRSP_ERROR_INVALID_ARGUMENT;
    }
    encoded = *slice;
    encoded.payload0_bytes = (uint32_t)payload0_bytes;
    encoded.payload1_bytes = (uint32_t)payload1_bytes;
    result = xrsp_build_encoded_slice(&encoded, &capnp, &capnp_bytes);
    if (result != XRSP_SUCCESS) {
        return result;
    }
    if (capnp_bytes < 8u) {
        free(capnp);
        return XRSP_ERROR_PROTOCOL;
    }

    topic = (uint8_t)(XRSP_STREAMING_TOPIC_SLICE_BASE + encoded.slice_index);
    result = topic_write_unlocked(connection, topic, capnp, 8u);
    if (result == XRSP_SUCCESS) {
        result = topic_write_unlocked(connection, topic, capnp + 8u, capnp_bytes - 8u);
    }
    if (result == XRSP_SUCCESS) {
        result = topic_write_unlocked(connection, topic, payload0, payload0_bytes);
    }
    if (result == XRSP_SUCCESS) {
        result = topic_write_unlocked(connection, topic, payload1, payload1_bytes);
    }
    free(capnp);
    return result;
}

xrsp_result
xrsp_send_encoded_slice(xrsp_connection *connection,
                        const xrsp_encoded_slice *slice,
                        const void *payload0,
                        size_t payload0_bytes,
                        const void *payload1,
                        size_t payload1_bytes)
{
    xrsp_result result;

    if (connection == NULL) {
        return XRSP_ERROR_INVALID_ARGUMENT;
    }
    lock_writes(connection);
    result = send_encoded_slice_unlocked(connection, slice, payload0, payload0_bytes, payload1,
                                         payload1_bytes);
    unlock_writes(connection);
    return result;
}

xrsp_result
xrsp_send_stock_client_frame(
    xrsp_connection *connection,
    uint32_t frame_id,
    int64_t timestamp_ns,
    const xrsp_stock_client_slice slices[XRSP_STOCK_CLIENT_SLICE_COUNT])
{
    size_t i;
    xrsp_result result = XRSP_SUCCESS;

    if (connection == NULL || slices == NULL) {
        return XRSP_ERROR_INVALID_ARGUMENT;
    }
    for (i = 0; i < XRSP_STOCK_CLIENT_SLICE_COUNT; i++) {
        if ((slices[i].codec_config.bytes != 0 && slices[i].codec_config.data == NULL) ||
            (slices[i].video.bytes != 0 && slices[i].video.data == NULL) ||
            slices[i].codec_config.bytes > UINT32_MAX || slices[i].video.bytes > UINT32_MAX) {
            return XRSP_ERROR_INVALID_ARGUMENT;
        }
    }
    lock_writes(connection);
    for (i = 0; i < XRSP_STOCK_CLIENT_SLICE_COUNT; i++) {
        xrsp_encoded_slice slice;
        size_t eye;
        size_t edge;

        memset(&slice, 0, sizeof(slice));
        slice.frame_id = frame_id;
        slice.orientation[3] = 1.0f;
        slice.frame_timestamp_ns = timestamp_ns;
        slice.slice_index = (uint8_t)i;
        slice.slice_flags = i + 1u == XRSP_STOCK_CLIENT_SLICE_COUNT ? 3u : 1u;
        slice.slice_y = (uint32_t)i * XRSP_STOCK_CLIENT_SLICE_HEIGHT;
        slice.slice_data_38 = 24;
        slice.slice_timestamp_ns = timestamp_ns;
        slice.slice_duration_ns = XRSP_STOCK_CLIENT_FRAME_DURATION_NS;
        slice.frame_timing_0_ns = timestamp_ns;
        slice.frame_timing_1_ns = timestamp_ns;
        slice.frame_timing_2_ns = timestamp_ns;
        for (eye = 0; eye < 2; eye++) {
            for (edge = 0; edge < 4; edge++) {
                slice.fov[eye][edge] = 1.0f;
            }
        }
        result = send_encoded_slice_unlocked(connection, &slice, slices[i].codec_config.data,
                                             slices[i].codec_config.bytes, slices[i].video.data,
                                             slices[i].video.bytes);
        if (result != XRSP_SUCCESS) {
            break;
        }
    }
    unlock_writes(connection);
    return result;
}

void
xrsp_free(void *memory)
{
    free(memory);
}
