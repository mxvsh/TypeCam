/*
 * TypeCam wire protocol v1 — constants and framing for docs/PROTOCOL.md.
 * Mirrors ios/TypeCam/Transport/Wire.swift; change both in the same commit.
 */

#pragma once

#include <stdbool.h>
#include <stdint.h>

#define TC_PORT 7878
#define TC_PROTOCOL_VERSION 1
#define TC_MAGIC 0x4354 /* bytes 'T' 'C' */
#define TC_HEADER_SIZE 16
#define TC_MAX_PAYLOAD (8u << 20)
#define TC_FLAG_KEYFRAME 0x01

enum tc_message_type {
	TC_HELLO = 0x01,
	TC_HELLO_ACK = 0x02,
	TC_VIDEO_CONFIG = 0x10,
	TC_VIDEO_FRAME = 0x11,
	TC_AUDIO_CONFIG = 0x20,
	TC_AUDIO_FRAME = 0x21,
	TC_DEVICE_STATUS = 0x30,
	TC_HOST_STATS = 0x31,
	TC_KEYFRAME_REQUEST = 0x32,
	TC_PING = 0x40,
	TC_PONG = 0x41,
	TC_STREAM_STATE = 0x50,
};

enum tc_codec {
	TC_CODEC_H264 = 1,
	TC_CODEC_HEVC = 2,
};

struct tc_header {
	uint8_t type;
	uint8_t flags;
	uint32_t length;
	uint64_t pts;
};

static inline uint16_t tc_read_u16(const uint8_t *p)
{
	return (uint16_t)(p[0] | (p[1] << 8));
}

static inline void tc_write_header(uint8_t out[TC_HEADER_SIZE], uint8_t type, uint8_t flags, uint32_t length,
				   uint64_t pts)
{
	out[0] = TC_MAGIC & 0xff;
	out[1] = TC_MAGIC >> 8;
	out[2] = type;
	out[3] = flags;
	for (int i = 0; i < 4; i++)
		out[4 + i] = (uint8_t)(length >> (8 * i));
	for (int i = 0; i < 8; i++)
		out[8 + i] = (uint8_t)(pts >> (8 * i));
}

/* Returns false on a bad magic or oversized payload; the caller must close the connection. */
static inline bool tc_read_header(const uint8_t in[TC_HEADER_SIZE], struct tc_header *header)
{
	if (tc_read_u16(in) != TC_MAGIC)
		return false;
	header->type = in[2];
	header->flags = in[3];
	header->length = 0;
	for (int i = 0; i < 4; i++)
		header->length |= (uint32_t)in[4 + i] << (8 * i);
	header->pts = 0;
	for (int i = 0; i < 8; i++)
		header->pts |= (uint64_t)in[8 + i] << (8 * i);
	return header->length <= TC_MAX_PAYLOAD;
}
