#include "audio-decoder.h"

#include <AudioToolbox/AudioToolbox.h>
#include <plugin-support.h>

#define AAC_FRAMES_PER_PACKET 1024
#define NO_MORE_INPUT ((OSStatus)0x74634e4d) /* our "input exhausted" status */

struct tc_audio_decoder {
	obs_source_t *source;
	bool configured;
	bool aac;
	uint32_t sample_rate;
	uint32_t channels;

	AudioConverterRef converter;
	float *pcm;
	const uint8_t *packet;
	uint32_t packet_size;
	bool packet_consumed;
	AudioStreamPacketDescription description;
};

struct tc_audio_decoder *tc_audio_decoder_create(obs_source_t *source)
{
	struct tc_audio_decoder *decoder = bzalloc(sizeof(*decoder));
	decoder->source = source;
	return decoder;
}

void tc_audio_decoder_reset(struct tc_audio_decoder *decoder)
{
	if (decoder->converter) {
		AudioConverterDispose(decoder->converter);
		decoder->converter = NULL;
	}
	bfree(decoder->pcm);
	decoder->pcm = NULL;
	decoder->configured = false;
}

void tc_audio_decoder_destroy(struct tc_audio_decoder *decoder)
{
	if (!decoder)
		return;
	tc_audio_decoder_reset(decoder);
	bfree(decoder);
}

bool tc_audio_decoder_configure(struct tc_audio_decoder *decoder, const char *json)
{
	obs_data_t *config = obs_data_create_from_json(json);
	if (!config)
		return false;
	bool aac = strcmp(obs_data_get_string(config, "format"), "aac") == 0;
	uint32_t rate = (uint32_t)obs_data_get_int(config, "sample_rate");
	uint32_t channels = (uint32_t)obs_data_get_int(config, "channels");
	obs_data_release(config);
	if (rate == 0 || channels == 0 || channels > 2)
		return false;

	if (decoder->configured && decoder->aac == aac && decoder->sample_rate == rate && decoder->channels == channels)
		return true;

	tc_audio_decoder_reset(decoder);
	decoder->aac = aac;
	decoder->sample_rate = rate;
	decoder->channels = channels;

	if (aac) {
		AudioStreamBasicDescription in = {
			.mSampleRate = rate,
			.mFormatID = kAudioFormatMPEG4AAC,
			.mFormatFlags = kMPEG4Object_AAC_LC,
			.mFramesPerPacket = AAC_FRAMES_PER_PACKET,
			.mChannelsPerFrame = channels,
		};
		AudioStreamBasicDescription out = {
			.mSampleRate = rate,
			.mFormatID = kAudioFormatLinearPCM,
			.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
			.mBytesPerPacket = 4 * channels,
			.mFramesPerPacket = 1,
			.mBytesPerFrame = 4 * channels,
			.mChannelsPerFrame = channels,
			.mBitsPerChannel = 32,
		};
		OSStatus status = AudioConverterNew(&in, &out, &decoder->converter);
		if (status != noErr) {
			obs_log(LOG_WARNING, "failed to create AAC decoder (%d)", (int)status);
			decoder->converter = NULL;
			return false;
		}
		decoder->pcm = bmalloc(AAC_FRAMES_PER_PACKET * channels * sizeof(float));
	}

	decoder->configured = true;
	obs_log(LOG_INFO, "audio: %s %u Hz, %u ch", aac ? "AAC" : "PCM", rate, channels);
	return true;
}

/* Hands AudioConverter exactly one packet per FillComplexBuffer call. */
static OSStatus provide_packet(AudioConverterRef converter, UInt32 *packets, AudioBufferList *data,
			       AudioStreamPacketDescription **description, void *user)
{
	UNUSED_PARAMETER(converter);
	struct tc_audio_decoder *decoder = user;
	if (decoder->packet_consumed) {
		*packets = 0;
		return NO_MORE_INPUT;
	}
	data->mNumberBuffers = 1;
	data->mBuffers[0].mData = (void *)decoder->packet;
	data->mBuffers[0].mDataByteSize = decoder->packet_size;
	data->mBuffers[0].mNumberChannels = decoder->channels;
	decoder->description = (AudioStreamPacketDescription){0, 0, decoder->packet_size};
	if (description)
		*description = &decoder->description;
	*packets = 1;
	decoder->packet_consumed = true;
	return noErr;
}

bool tc_audio_decoder_decode(struct tc_audio_decoder *decoder, const uint8_t *data, size_t length,
			     uint64_t timestamp)
{
	if (!decoder->configured || length == 0)
		return false;

	struct obs_source_audio audio = {0};
	audio.speakers = decoder->channels == 2 ? SPEAKERS_STEREO : SPEAKERS_MONO;
	audio.samples_per_sec = decoder->sample_rate;
	audio.timestamp = timestamp;

	if (!decoder->aac) {
		audio.data[0] = data;
		audio.frames = (uint32_t)(length / (2 * decoder->channels));
		audio.format = AUDIO_FORMAT_16BIT;
	} else {
		if (!decoder->converter)
			return false;
		decoder->packet = data;
		decoder->packet_size = (uint32_t)length;
		decoder->packet_consumed = false;

		UInt32 frames = AAC_FRAMES_PER_PACKET;
		AudioBufferList output = {
			.mNumberBuffers = 1,
			.mBuffers = {{decoder->channels, frames * 4 * decoder->channels, decoder->pcm}},
		};
		OSStatus status = AudioConverterFillComplexBuffer(decoder->converter, provide_packet, decoder, &frames,
								  &output, NULL);
		if ((status != noErr && status != NO_MORE_INPUT) || frames == 0)
			return status == NO_MORE_INPUT; /* decoder priming: no output yet */
		audio.data[0] = (const uint8_t *)decoder->pcm;
		audio.frames = frames;
		audio.format = AUDIO_FORMAT_FLOAT;
	}

	obs_source_output_audio(decoder->source, &audio);
	return true;
}
