/*
 * Hardware H.264/HEVC decoder (VideoToolbox) that outputs NV12 frames to an async OBS source,
 * applying the stream's display rotation.
 */

#pragma once

#include <obs-module.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

struct tc_decoder;

struct tc_decoder *tc_decoder_create(obs_source_t *source);
void tc_decoder_destroy(struct tc_decoder *decoder);

/* Applies a VIDEO_CONFIG. Keeps the session when the format is compatible. */
bool tc_decoder_configure(struct tc_decoder *decoder, int codec, const uint8_t *const *parameter_sets,
			  const size_t *sizes, size_t count, int rotation);

/* Decodes one AVCC access unit. Returns false on error (the caller should request a keyframe). */
bool tc_decoder_decode(struct tc_decoder *decoder, const uint8_t *data, size_t length, uint64_t pts_ns);

/* Drops the session, e.g. after a disconnect. */
void tc_decoder_reset(struct tc_decoder *decoder);

/* Offset added to phone PTS to land on the OBS clock (shared with audio for A/V sync). */
void tc_decoder_set_ts_offset(struct tc_decoder *decoder, uint64_t offset);

/* Frames delivered to OBS since the last call. */
uint32_t tc_decoder_take_frame_count(struct tc_decoder *decoder);

/* Average decode time over recent frames, in milliseconds. */
double tc_decoder_decode_ms(struct tc_decoder *decoder);
