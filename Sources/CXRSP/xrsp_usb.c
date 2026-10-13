#include "xrsp_usb.h"

#include <libusb.h>
#include <stdlib.h>
#include <string.h>

struct xrsp_usb_device {
    libusb_context *context;
    libusb_device_handle *handle;
    uint16_t vendor_id;
    uint16_t product_id;
    int interface_number;
    uint8_t endpoint_in;
    uint8_t endpoint_out;
    unsigned int timeout_ms;
    bool claimed;
    uint8_t read_buffer[XRSP_USB_CHUNK_BYTES];
    size_t read_buffer_offset;
    size_t read_buffer_bytes;
};

static ptrdiff_t
usb_read(void *user, void *data, size_t bytes)
{
    xrsp_usb_device *device = user;
    int transferred = 0;
    int result;
    size_t available;
    size_t copy_bytes;

    if (device == NULL || data == NULL || bytes == 0) {
        return -1;
    }
    available = device->read_buffer_bytes - device->read_buffer_offset;
    if (available != 0) {
        copy_bytes = bytes < available ? bytes : available;
        memcpy(data, device->read_buffer + device->read_buffer_offset, copy_bytes);
        device->read_buffer_offset += copy_bytes;
        if (device->read_buffer_offset == device->read_buffer_bytes) {
            device->read_buffer_offset = 0;
            device->read_buffer_bytes = 0;
        }
        return (ptrdiff_t)copy_bytes;
    }

    result = libusb_bulk_transfer(device->handle,
                                  device->endpoint_in,
                                  device->read_buffer,
                                  XRSP_USB_CHUNK_BYTES,
                                  &transferred,
                                  device->timeout_ms);
    if (result == LIBUSB_ERROR_TIMEOUT) {
        if (transferred == 0) {
            return XRSP_IO_RETRY;
        }
    } else if (result != LIBUSB_SUCCESS) {
        return -1;
    }
    if (transferred <= 0 || transferred > (int)XRSP_USB_CHUNK_BYTES) {
        return -1;
    }
    device->read_buffer_bytes = (size_t)transferred;
    copy_bytes = bytes < device->read_buffer_bytes ? bytes : device->read_buffer_bytes;
    memcpy(data, device->read_buffer, copy_bytes);
    device->read_buffer_offset = copy_bytes;
    if (device->read_buffer_offset == device->read_buffer_bytes) {
        device->read_buffer_offset = 0;
        device->read_buffer_bytes = 0;
    }
    return (ptrdiff_t)copy_bytes;
}

static ptrdiff_t
usb_write(void *user, const void *data, size_t bytes)
{
    xrsp_usb_device *device = user;
    int transferred = 0;
    int request;
    int result;

    if (device == NULL || data == NULL || bytes == 0) {
        return -1;
    }
    request = bytes > XRSP_USB_CHUNK_BYTES ? (int)XRSP_USB_CHUNK_BYTES : (int)bytes;
    result = libusb_bulk_transfer(device->handle,
                                  device->endpoint_out,
                                  (unsigned char *)(uintptr_t)data,
                                  request,
                                  &transferred,
                                  device->timeout_ms);
    if (result == LIBUSB_ERROR_TIMEOUT) {
        return transferred > 0 ? transferred : XRSP_IO_RETRY;
    }
    if (result != LIBUSB_SUCCESS) {
        return -1;
    }
    return transferred;
}

void
xrsp_usb_options_init(xrsp_usb_options *options)
{
    if (options == NULL) {
        return;
    }
    memset(options, 0, sizeof(*options));
    options->interface_number = -1;
    options->timeout_ms = 1000;
}

static bool
matches_device(const xrsp_usb_options *options, const struct libusb_device_descriptor *descriptor)
{
    return (options->vendor_id == 0 || options->vendor_id == descriptor->idVendor) &&
           (options->product_id == 0 || options->product_id == descriptor->idProduct);
}

static bool
find_interface_in_config(const struct libusb_config_descriptor *config,
                         const xrsp_usb_options *options,
                         int *out_configuration,
                         int *out_interface,
                         int *out_alt_setting,
                         uint8_t *out_endpoint_in,
                         uint8_t *out_endpoint_out)
{
    int interface_index;

    for (interface_index = 0; interface_index < config->bNumInterfaces; interface_index++) {
        const struct libusb_interface *interface = &config->interface[interface_index];
        int alt_index;

        for (alt_index = 0; alt_index < interface->num_altsetting; alt_index++) {
            const struct libusb_interface_descriptor *alt = &interface->altsetting[alt_index];
            uint8_t endpoint_in = 0;
            uint8_t endpoint_out = 0;
            uint8_t endpoint_index;

            if (options->interface_number >= 0 &&
                alt->bInterfaceNumber != options->interface_number) {
                continue;
            }
            for (endpoint_index = 0; endpoint_index < alt->bNumEndpoints; endpoint_index++) {
                const struct libusb_endpoint_descriptor *endpoint = &alt->endpoint[endpoint_index];
                if ((endpoint->bmAttributes & LIBUSB_TRANSFER_TYPE_MASK) !=
                    LIBUSB_TRANSFER_TYPE_BULK) {
                    continue;
                }
                if ((endpoint->bEndpointAddress & LIBUSB_ENDPOINT_DIR_MASK) ==
                    LIBUSB_ENDPOINT_IN) {
                    if (options->endpoint_in == 0 ||
                        options->endpoint_in == endpoint->bEndpointAddress) {
                        endpoint_in = endpoint->bEndpointAddress;
                    }
                } else if (options->endpoint_out == 0 ||
                           options->endpoint_out == endpoint->bEndpointAddress) {
                    endpoint_out = endpoint->bEndpointAddress;
                }
            }
            if (endpoint_in != 0 && endpoint_out != 0) {
                *out_configuration = config->bConfigurationValue;
                *out_interface = alt->bInterfaceNumber;
                *out_alt_setting = alt->bAlternateSetting;
                *out_endpoint_in = endpoint_in;
                *out_endpoint_out = endpoint_out;
                return true;
            }
        }
    }
    return false;
}

static bool
find_interface(libusb_device *device,
               const xrsp_usb_options *options,
               int *out_configuration,
               int *out_interface,
               int *out_alt_setting,
               uint8_t *out_endpoint_in,
               uint8_t *out_endpoint_out)
{
    struct libusb_device_descriptor descriptor;
    struct libusb_config_descriptor *active_config = NULL;
    uint8_t active_value = 0;
    uint8_t config_index;

    if (libusb_get_device_descriptor(device, &descriptor) != LIBUSB_SUCCESS ||
        !matches_device(options, &descriptor)) {
        return false;
    }
    if (libusb_get_active_config_descriptor(device, &active_config) == LIBUSB_SUCCESS) {
        active_value = active_config->bConfigurationValue;
        if (find_interface_in_config(active_config,
                                     options,
                                     out_configuration,
                                     out_interface,
                                     out_alt_setting,
                                     out_endpoint_in,
                                     out_endpoint_out)) {
            libusb_free_config_descriptor(active_config);
            return true;
        }
        libusb_free_config_descriptor(active_config);
    }

    for (config_index = 0; config_index < descriptor.bNumConfigurations; config_index++) {
        struct libusb_config_descriptor *config = NULL;
        bool found;

        if (libusb_get_config_descriptor(device, config_index, &config) != LIBUSB_SUCCESS) {
            continue;
        }
        if (config->bConfigurationValue == active_value) {
            libusb_free_config_descriptor(config);
            continue;
        }
        found = find_interface_in_config(config,
                                         options,
                                         out_configuration,
                                         out_interface,
                                         out_alt_setting,
                                         out_endpoint_in,
                                         out_endpoint_out);
        libusb_free_config_descriptor(config);
        if (found) {
            return true;
        }
    }
    return false;
}

xrsp_result
xrsp_usb_open(const xrsp_usb_options *options, xrsp_usb_device **out_device, xrsp_io *out_io)
{
    xrsp_usb_options selected;
    xrsp_usb_device *result_device = NULL;
    libusb_device **devices = NULL;
    ssize_t device_count;
    ssize_t i;
    xrsp_result result = XRSP_ERROR_IO;

    if (out_device == NULL || out_io == NULL) {
        return XRSP_ERROR_INVALID_ARGUMENT;
    }
    xrsp_usb_options_init(&selected);
    if (options != NULL) {
        selected = *options;
    }
    if ((selected.endpoint_in != 0 &&
         (selected.endpoint_in & LIBUSB_ENDPOINT_DIR_MASK) != LIBUSB_ENDPOINT_IN) ||
        (selected.endpoint_out != 0 &&
         (selected.endpoint_out & LIBUSB_ENDPOINT_DIR_MASK) != LIBUSB_ENDPOINT_OUT)) {
        return XRSP_ERROR_INVALID_ARGUMENT;
    }

    result_device = calloc(1, sizeof(*result_device));
    if (result_device == NULL) {
        return XRSP_ERROR_NO_MEMORY;
    }
    if (libusb_init(&result_device->context) != LIBUSB_SUCCESS) {
        free(result_device);
        return XRSP_ERROR_IO;
    }

    device_count = libusb_get_device_list(result_device->context, &devices);
    if (device_count < 0) {
        xrsp_usb_close(result_device);
        return XRSP_ERROR_IO;
    }
    for (i = 0; i < device_count; i++) {
        struct libusb_device_descriptor descriptor;
        int configuration = 0;
        int interface_number = -1;
        int alt_setting = 0;
        uint8_t endpoint_in = 0;
        uint8_t endpoint_out = 0;
        libusb_device_handle *handle = NULL;

        if (!find_interface(devices[i],
                            &selected,
                            &configuration,
                            &interface_number,
                            &alt_setting,
                            &endpoint_in,
                            &endpoint_out) ||
            libusb_get_device_descriptor(devices[i], &descriptor) != LIBUSB_SUCCESS ||
            libusb_open(devices[i], &handle) != LIBUSB_SUCCESS) {
            continue;
        }

        {
            int active_configuration = 0;
            if (libusb_get_configuration(handle, &active_configuration) != LIBUSB_SUCCESS) {
                libusb_close(handle);
                continue;
            }
            if (active_configuration != configuration &&
                libusb_set_configuration(handle, configuration) != LIBUSB_SUCCESS) {
                libusb_close(handle);
                continue;
            }
        }
        if (libusb_kernel_driver_active(handle, interface_number) == 1) {
            (void)libusb_detach_kernel_driver(handle, interface_number);
        }
        if (libusb_claim_interface(handle, interface_number) != LIBUSB_SUCCESS) {
            libusb_close(handle);
            continue;
        }
        if (alt_setting != 0 &&
            libusb_set_interface_alt_setting(handle, interface_number, alt_setting) !=
                LIBUSB_SUCCESS) {
            libusb_release_interface(handle, interface_number);
            libusb_close(handle);
            continue;
        }

        result_device->handle = handle;
        result_device->vendor_id = descriptor.idVendor;
        result_device->product_id = descriptor.idProduct;
        result_device->interface_number = interface_number;
        result_device->endpoint_in = endpoint_in;
        result_device->endpoint_out = endpoint_out;
        result_device->timeout_ms = selected.timeout_ms;
        result_device->claimed = true;
        result = XRSP_SUCCESS;
        break;
    }
    libusb_free_device_list(devices, 1);

    if (result != XRSP_SUCCESS) {
        xrsp_usb_close(result_device);
        return result;
    }
    out_io->user = result_device;
    out_io->read = usb_read;
    out_io->write = usb_write;
    *out_device = result_device;
    return XRSP_SUCCESS;
}

void
xrsp_usb_close(xrsp_usb_device *device)
{
    if (device == NULL) {
        return;
    }
    if (device->handle != NULL) {
        if (device->claimed) {
            (void)libusb_release_interface(device->handle, device->interface_number);
        }
        libusb_close(device->handle);
    }
    if (device->context != NULL) {
        libusb_exit(device->context);
    }
    free(device);
}

uint16_t
xrsp_usb_vendor_id(const xrsp_usb_device *device)
{
    return device != NULL ? device->vendor_id : 0;
}

uint16_t
xrsp_usb_product_id(const xrsp_usb_device *device)
{
    return device != NULL ? device->product_id : 0;
}

int
xrsp_usb_interface_number(const xrsp_usb_device *device)
{
    return device != NULL ? device->interface_number : -1;
}

uint8_t
xrsp_usb_endpoint_in(const xrsp_usb_device *device)
{
    return device != NULL ? device->endpoint_in : 0;
}

uint8_t
xrsp_usb_endpoint_out(const xrsp_usb_device *device)
{
    return device != NULL ? device->endpoint_out : 0;
}
