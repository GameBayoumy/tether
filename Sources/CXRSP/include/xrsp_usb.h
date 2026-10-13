#pragma once

#include "xrsp.h"

#ifdef __cplusplus
extern "C" {
#endif

#define XRSP_USB_CHUNK_BYTES 0x400u

typedef struct xrsp_usb_device xrsp_usb_device;

typedef struct xrsp_usb_options {
    uint16_t vendor_id;
    uint16_t product_id;
    int interface_number;
    uint8_t endpoint_in;
    uint8_t endpoint_out;
    unsigned int timeout_ms;
} xrsp_usb_options;

void xrsp_usb_options_init(xrsp_usb_options *options);

/*
 * Opens the first matching bulk interface. A zero VID/PID matches any device,
 * a negative interface number matches any interface, and zero endpoints select
 * the first bulk endpoint in the required direction.
 */
xrsp_result xrsp_usb_open(const xrsp_usb_options *options,
                          xrsp_usb_device **out_device,
                          xrsp_io *out_io);
void xrsp_usb_close(xrsp_usb_device *device);

uint16_t xrsp_usb_vendor_id(const xrsp_usb_device *device);
uint16_t xrsp_usb_product_id(const xrsp_usb_device *device);
int xrsp_usb_interface_number(const xrsp_usb_device *device);
uint8_t xrsp_usb_endpoint_in(const xrsp_usb_device *device);
uint8_t xrsp_usb_endpoint_out(const xrsp_usb_device *device);

#ifdef __cplusplus
}
#endif
