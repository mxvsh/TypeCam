/*
 * usbmuxd client. Each request uses a fresh socket: a 16-byte header (length, version 1,
 * type 8 = plist, tag) followed by an XML plist. After a successful Connect the socket
 * becomes a raw byte pipe to the device port.
 */

#include "usbmux.h"

#include <CoreFoundation/CoreFoundation.h>
#include <arpa/inet.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/un.h>
#include <unistd.h>

#define USBMUXD_SOCKET "/var/run/usbmuxd"
#define USBMUX_PLIST_VERSION 1
#define USBMUX_PLIST_MESSAGE 8
#define USBMUX_MAX_REPLY (1u << 20)

static bool write_all(int fd, const void *buffer, size_t length)
{
	const uint8_t *p = buffer;
	while (length > 0) {
		ssize_t n = send(fd, p, length, 0);
		if (n <= 0)
			return false;
		p += n;
		length -= (size_t)n;
	}
	return true;
}

static bool read_all(int fd, void *buffer, size_t length)
{
	uint8_t *p = buffer;
	while (length > 0) {
		ssize_t n = recv(fd, p, length, 0);
		if (n <= 0)
			return false;
		p += n;
		length -= (size_t)n;
	}
	return true;
}

static int mux_open(void)
{
	int fd = socket(AF_UNIX, SOCK_STREAM, 0);
	if (fd < 0)
		return -1;

	struct sockaddr_un addr = {0};
	addr.sun_family = AF_UNIX;
	strlcpy(addr.sun_path, USBMUXD_SOCKET, sizeof(addr.sun_path));
	if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
		close(fd);
		return -1;
	}

	int on = 1;
	setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof(on));
	struct timeval timeout = {.tv_sec = 2};
	setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
	return fd;
}

static CFMutableDictionaryRef mux_message(CFStringRef type)
{
	CFMutableDictionaryRef message = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks,
								   &kCFTypeDictionaryValueCallBacks);
	CFDictionarySetValue(message, CFSTR("MessageType"), type);
	CFDictionarySetValue(message, CFSTR("ClientVersionString"), CFSTR("obs-typecam"));
	CFDictionarySetValue(message, CFSTR("ProgName"), CFSTR("obs-typecam"));
	return message;
}

static void dict_set_int(CFMutableDictionaryRef dict, CFStringRef key, int64_t value)
{
	CFNumberRef number = CFNumberCreate(NULL, kCFNumberSInt64Type, &value);
	CFDictionarySetValue(dict, key, number);
	CFRelease(number);
}

static bool dict_get_int(CFDictionaryRef dict, CFStringRef key, int64_t *value)
{
	CFTypeRef ref = CFDictionaryGetValue(dict, key);
	return ref && CFGetTypeID(ref) == CFNumberGetTypeID() && CFNumberGetValue(ref, kCFNumberSInt64Type, value);
}

/* Sends `message` and returns the reply dictionary (caller releases), or NULL. */
static CFDictionaryRef mux_request(int fd, CFDictionaryRef message, uint32_t tag)
{
	CFDataRef body = CFPropertyListCreateData(NULL, message, kCFPropertyListXMLFormat_v1_0, 0, NULL);
	if (!body)
		return NULL;

	uint32_t length = (uint32_t)CFDataGetLength(body);
	uint32_t header[4] = {16 + length, USBMUX_PLIST_VERSION, USBMUX_PLIST_MESSAGE, tag};
	bool sent = write_all(fd, header, sizeof(header)) && write_all(fd, CFDataGetBytePtr(body), length);
	CFRelease(body);
	if (!sent || !read_all(fd, header, sizeof(header)) || header[0] < 16 || header[0] - 16 > USBMUX_MAX_REPLY)
		return NULL;

	uint32_t reply_length = header[0] - 16;
	uint8_t *reply = malloc(reply_length);
	if (!reply)
		return NULL;
	if (!read_all(fd, reply, reply_length)) {
		free(reply);
		return NULL;
	}
	CFDataRef data = CFDataCreateWithBytesNoCopy(NULL, reply, reply_length, kCFAllocatorMalloc);
	CFPropertyListRef plist = CFPropertyListCreateWithData(NULL, data, kCFPropertyListImmutable, NULL, NULL);
	CFRelease(data);
	if (plist && CFGetTypeID(plist) != CFDictionaryGetTypeID()) {
		CFRelease(plist);
		return NULL;
	}
	return plist;
}

size_t usbmux_list_devices(struct usbmux_device *out, size_t max)
{
	int fd = mux_open();
	if (fd < 0)
		return 0;

	CFMutableDictionaryRef message = mux_message(CFSTR("ListDevices"));
	CFDictionaryRef reply = mux_request(fd, message, 1);
	CFRelease(message);
	close(fd);
	if (!reply)
		return 0;

	size_t count = 0;
	CFArrayRef list = CFDictionaryGetValue(reply, CFSTR("DeviceList"));
	if (list && CFGetTypeID(list) == CFArrayGetTypeID()) {
		for (CFIndex i = 0; i < CFArrayGetCount(list) && count < max; i++) {
			CFDictionaryRef entry = CFArrayGetValueAtIndex(list, i);
			if (CFGetTypeID(entry) != CFDictionaryGetTypeID())
				continue;
			CFDictionaryRef props = CFDictionaryGetValue(entry, CFSTR("Properties"));
			if (!props || CFGetTypeID(props) != CFDictionaryGetTypeID())
				continue;

			CFStringRef connection = CFDictionaryGetValue(props, CFSTR("ConnectionType"));
			CFStringRef serial = CFDictionaryGetValue(props, CFSTR("SerialNumber"));
			int64_t device_id;
			if (!connection || CFGetTypeID(connection) != CFStringGetTypeID() ||
			    CFStringCompare(connection, CFSTR("USB"), 0) != kCFCompareEqualTo || !serial ||
			    CFGetTypeID(serial) != CFStringGetTypeID() || !dict_get_int(props, CFSTR("DeviceID"), &device_id))
				continue;

			out[count].device_id = (uint32_t)device_id;
			if (CFStringGetCString(serial, out[count].udid, sizeof(out[count].udid), kCFStringEncodingUTF8))
				count++;
		}
	}
	CFRelease(reply);
	return count;
}

int usbmux_connect(uint32_t device_id, uint16_t port)
{
	int fd = mux_open();
	if (fd < 0)
		return -1;

	CFMutableDictionaryRef message = mux_message(CFSTR("Connect"));
	dict_set_int(message, CFSTR("DeviceID"), device_id);
	dict_set_int(message, CFSTR("PortNumber"), htons(port)); /* network byte order, per usbmuxd */
	CFDictionaryRef reply = mux_request(fd, message, 2);
	CFRelease(message);

	int64_t result = -1;
	if (reply) {
		dict_get_int(reply, CFSTR("Number"), &result);
		CFRelease(reply);
	}
	if (result != 0) {
		close(fd);
		return -1;
	}
	return fd;
}
