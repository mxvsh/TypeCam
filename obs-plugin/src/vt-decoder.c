#include "vt-decoder.h"
#include "protocol.h"

#include <CoreMedia/CoreMedia.h>
#include <CoreVideo/CoreVideo.h>
#include <VideoToolbox/VideoToolbox.h>
#include <media-io/video-io.h>
#include <util/platform.h>

struct tc_decoder {
	obs_source_t *source;
	CMVideoFormatDescriptionRef format;
	VTDecompressionSessionRef session;

	int rotation;
	VTPixelRotationSessionRef rotator;
	int rotator_angle;
	CVPixelBufferPoolRef pool;
	size_t pool_width;
	size_t pool_height;

	uint64_t ts_offset;
	bool output_error;
	uint32_t frames;
	double decode_ms;
};

struct tc_decoder *tc_decoder_create(obs_source_t *source)
{
	struct tc_decoder *decoder = bzalloc(sizeof(*decoder));
	decoder->source = source;
	return decoder;
}

static void release_session(struct tc_decoder *decoder)
{
	if (decoder->session) {
		VTDecompressionSessionWaitForAsynchronousFrames(decoder->session);
		VTDecompressionSessionInvalidate(decoder->session);
		CFRelease(decoder->session);
		decoder->session = NULL;
	}
	if (decoder->format) {
		CFRelease(decoder->format);
		decoder->format = NULL;
	}
}

void tc_decoder_reset(struct tc_decoder *decoder)
{
	release_session(decoder);
}

void tc_decoder_set_ts_offset(struct tc_decoder *decoder, uint64_t offset)
{
	decoder->ts_offset = offset;
}

void tc_decoder_destroy(struct tc_decoder *decoder)
{
	if (!decoder)
		return;
	release_session(decoder);
	if (decoder->rotator) {
		VTPixelRotationSessionInvalidate(decoder->rotator);
		CFRelease(decoder->rotator);
	}
	if (decoder->pool)
		CVPixelBufferPoolRelease(decoder->pool);
	bfree(decoder);
}

/* ---- Rotation ----------------------------------------------------------- */

static CFDictionaryRef nv12_attributes(size_t width, size_t height)
{
	CFMutableDictionaryRef attrs = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks,
								 &kCFTypeDictionaryValueCallBacks);
	int32_t format = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
	CFNumberRef number = CFNumberCreate(NULL, kCFNumberSInt32Type, &format);
	CFDictionarySetValue(attrs, kCVPixelBufferPixelFormatTypeKey, number);
	CFRelease(number);
	if (width && height) {
		int32_t w = (int32_t)width, h = (int32_t)height;
		number = CFNumberCreate(NULL, kCFNumberSInt32Type, &w);
		CFDictionarySetValue(attrs, kCVPixelBufferWidthKey, number);
		CFRelease(number);
		number = CFNumberCreate(NULL, kCFNumberSInt32Type, &h);
		CFDictionarySetValue(attrs, kCVPixelBufferHeightKey, number);
		CFRelease(number);
	}
	CFDictionaryRef surface = CFDictionaryCreate(NULL, NULL, NULL, 0, &kCFTypeDictionaryKeyCallBacks,
						     &kCFTypeDictionaryValueCallBacks);
	CFDictionarySetValue(attrs, kCVPixelBufferIOSurfacePropertiesKey, surface);
	CFRelease(surface);
	return attrs;
}

/* Returns a rotated copy (caller releases), or NULL to fall back to the unrotated image. */
static CVPixelBufferRef rotate(struct tc_decoder *decoder, CVPixelBufferRef source)
{
	if (!decoder->rotator && VTPixelRotationSessionCreate(NULL, &decoder->rotator) != noErr)
		return NULL;
	if (decoder->rotator_angle != decoder->rotation) {
		CFStringRef angle = decoder->rotation == 90    ? kVTRotation_CW90
				    : decoder->rotation == 180 ? kVTRotation_180
							       : kVTRotation_CCW90;
		VTSessionSetProperty(decoder->rotator, kVTPixelRotationPropertyKey_Rotation, angle);
		decoder->rotator_angle = decoder->rotation;
	}

	size_t width = CVPixelBufferGetWidth(source);
	size_t height = CVPixelBufferGetHeight(source);
	bool swap = decoder->rotation % 180 != 0;
	size_t out_width = swap ? height : width;
	size_t out_height = swap ? width : height;

	if (!decoder->pool || decoder->pool_width != out_width || decoder->pool_height != out_height) {
		if (decoder->pool)
			CVPixelBufferPoolRelease(decoder->pool);
		decoder->pool = NULL;
		CFDictionaryRef attrs = nv12_attributes(out_width, out_height);
		CVReturn status = CVPixelBufferPoolCreate(NULL, NULL, attrs, &decoder->pool);
		CFRelease(attrs);
		if (status != kCVReturnSuccess)
			return NULL;
		decoder->pool_width = out_width;
		decoder->pool_height = out_height;
	}

	CVPixelBufferRef rotated = NULL;
	if (CVPixelBufferPoolCreatePixelBuffer(NULL, decoder->pool, &rotated) != kCVReturnSuccess)
		return NULL;
	if (VTPixelRotationSessionRotateImage(decoder->rotator, source, rotated) != noErr) {
		CVPixelBufferRelease(rotated);
		return NULL;
	}
	return rotated;
}

/* ---- Output ------------------------------------------------------------- */

static void decoder_output(void *refcon, void *frame_refcon, OSStatus status, VTDecodeInfoFlags flags,
			   CVImageBufferRef image, CMTime pts, CMTime duration)
{
	UNUSED_PARAMETER(frame_refcon);
	UNUSED_PARAMETER(flags);
	UNUSED_PARAMETER(duration);
	struct tc_decoder *decoder = refcon;
	if (status != noErr || !image) {
		decoder->output_error = true;
		return;
	}

	CVPixelBufferRef rotated = decoder->rotation ? rotate(decoder, image) : NULL;
	CVPixelBufferRef buffer = rotated ? rotated : image;
	CVPixelBufferLockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);

	struct obs_source_frame frame = {0};
	frame.format = VIDEO_FORMAT_NV12;
	frame.width = (uint32_t)CVPixelBufferGetWidth(buffer);
	frame.height = (uint32_t)CVPixelBufferGetHeight(buffer);
	for (size_t plane = 0; plane < 2; plane++) {
		frame.data[plane] = CVPixelBufferGetBaseAddressOfPlane(buffer, plane);
		frame.linesize[plane] = (uint32_t)CVPixelBufferGetBytesPerRowOfPlane(buffer, plane);
	}
	frame.full_range = true;
	video_format_get_parameters_for_format(VIDEO_CS_709, VIDEO_RANGE_FULL, VIDEO_FORMAT_NV12, frame.color_matrix,
					       frame.color_range_min, frame.color_range_max);

	uint64_t pts_ns = (uint64_t)CMTimeConvertScale(pts, 1000000000, kCMTimeRoundingMethod_Default).value;
	frame.timestamp = pts_ns + decoder->ts_offset;

	/* OBS copies the frame before returning. */
	obs_source_output_video(decoder->source, &frame);

	CVPixelBufferUnlockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
	if (rotated)
		CVPixelBufferRelease(rotated);
	decoder->frames++;
}

/* ---- Configure / decode ------------------------------------------------- */

bool tc_decoder_configure(struct tc_decoder *decoder, int codec, const uint8_t *const *parameter_sets,
			  const size_t *sizes, size_t count, int rotation)
{
	decoder->rotation = ((rotation % 360) + 360) % 360;

	CMVideoFormatDescriptionRef format = NULL;
	OSStatus status;
	if (codec == TC_CODEC_HEVC)
		status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(NULL, count, parameter_sets, sizes, 4,
									     NULL, &format);
	else
		status = CMVideoFormatDescriptionCreateFromH264ParameterSets(NULL, count, parameter_sets, sizes, 4,
									     &format);
	if (status != noErr) {
		blog(LOG_WARNING, "[obs-typecam] invalid parameter sets (%d)", (int)status);
		return false;
	}

	if (decoder->format && CMFormatDescriptionEqual(decoder->format, format)) {
		CFRelease(format); /* rotation-only change */
		return true;
	}
	if (decoder->session && VTDecompressionSessionCanAcceptFormatDescription(decoder->session, format)) {
		CFRelease(decoder->format);
		decoder->format = format;
		return true;
	}

	release_session(decoder);
	decoder->format = format;

	CFDictionaryRef attrs = nv12_attributes(0, 0);
	VTDecompressionOutputCallbackRecord callback = {decoder_output, decoder};
	status = VTDecompressionSessionCreate(NULL, format, NULL, attrs, &callback, &decoder->session);
	CFRelease(attrs);
	if (status != noErr) {
		blog(LOG_WARNING, "[obs-typecam] failed to create decoder (%d)", (int)status);
		decoder->session = NULL;
		return false;
	}
	VTSessionSetProperty(decoder->session, kVTDecompressionPropertyKey_RealTime, kCFBooleanTrue);
	return true;
}

bool tc_decoder_decode(struct tc_decoder *decoder, const uint8_t *data, size_t length, uint64_t pts_ns)
{
	if (!decoder->session)
		return false;

	CMBlockBufferRef block = NULL;
	if (CMBlockBufferCreateWithMemoryBlock(NULL, NULL, length, kCFAllocatorDefault, NULL, 0, length,
					       kCMBlockBufferAssureMemoryNowFlag, &block) != kCMBlockBufferNoErr)
		return false;
	CMBlockBufferReplaceDataBytes(data, block, 0, length);

	CMSampleTimingInfo timing = {kCMTimeInvalid, CMTimeMake((int64_t)pts_ns, 1000000000), kCMTimeInvalid};
	CMSampleBufferRef sample = NULL;
	OSStatus status = CMSampleBufferCreateReady(NULL, block, decoder->format, 1, 1, &timing, 1, &length, &sample);
	CFRelease(block);
	if (status != noErr)
		return false;

	uint64_t start = os_gettime_ns();
	decoder->output_error = false;
	/* Synchronous decode: the output callback runs before this returns. */
	status = VTDecompressionSessionDecodeFrame(decoder->session, sample, 0, NULL, NULL);
	CFRelease(sample);

	double ms = (double)(os_gettime_ns() - start) / 1e6;
	decoder->decode_ms = decoder->decode_ms * 0.9 + ms * 0.1;

	if (status == kVTInvalidSessionErr) {
		/* e.g. after sleep/wake: recreate on the next config. */
		release_session(decoder);
		return false;
	}
	return status == noErr && !decoder->output_error;
}

uint32_t tc_decoder_take_frame_count(struct tc_decoder *decoder)
{
	uint32_t frames = decoder->frames;
	decoder->frames = 0;
	return frames;
}

double tc_decoder_decode_ms(struct tc_decoder *decoder)
{
	return decoder->decode_ms;
}
