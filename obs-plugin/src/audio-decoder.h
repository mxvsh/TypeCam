/*
 * AUDIO_CONFIG / AUDIO_FRAME → obs_source_output_audio(). PCM s16le is passed straight through;
 * AAC-LC is decoded with AudioToolbox.
 */

#pragma once

#include <obs-module.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

struct tc_audio_decoder;

struct tc_audio_decoder *tc_audio_decoder_create(obs_source_t *source);
void tc_audio_decoder_destroy(struct tc_audio_decoder *decoder);

/* Applies an AUDIO_CONFIG JSON payload. */
bool tc_audio_decoder_configure(struct tc_audio_decoder *decoder, const char *json);

/* Decodes one AUDIO_FRAME; `timestamp` is already on the OBS clock. */
bool tc_audio_decoder_decode(struct tc_audio_decoder *decoder, const uint8_t *data, size_t length,
			     uint64_t timestamp);

void tc_audio_decoder_reset(struct tc_audio_decoder *decoder);
