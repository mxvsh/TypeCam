/*
 * Minimal client for Apple's usbmuxd (/var/run/usbmuxd, plist protocol).
 */

#pragma once

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

struct usbmux_device {
	uint32_t device_id; /* usbmuxd's id; changes on every re-plug */
	char udid[64];      /* stable identifier, used to remember a device */
};

/* Lists USB-attached devices (network-paired devices are skipped). Returns the count written. */
size_t usbmux_list_devices(struct usbmux_device *out, size_t max);

/* Opens a TCP tunnel to `port` on the device. Returns a connected socket, or -1. */
int usbmux_connect(uint32_t device_id, uint16_t port);

#ifdef __cplusplus
}
#endif
