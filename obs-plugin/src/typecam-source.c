/*
 * "TypeCam (iPhone)" async video source. One connection thread per source: pick a device,
 * tunnel to TCP 7878 through usbmuxd, HELLO, then demux the stream (docs/PROTOCOL.md).
 */

#include "device-registry.h"
#include "protocol.h"
#include "usbmux.h"
#include "vt-decoder.h"

#include <obs-module.h>
#include <plugin-support.h>
#include <util/platform.h>
#include <util/threading.h>

#include <errno.h>
#include <poll.h>
#include <pthread.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

#define S_DEVICE "device"
#define S_UNBUFFERED "unbuffered"
#define S_IDLE "idle_behavior"
#define S_STATUS "status"
#define S_REFRESH "refresh"
#define S_KEYFRAME "request_keyframe"

#define IDLE_KEEP "keep"
#define IDLE_CLEAR "clear"

#define MAX_DEVICES 16
#define LIVENESS_TIMEOUT_NS (3 * 1000000000ULL)
#define TICK_NS 1000000000ULL

struct typecam_source {
	obs_source_t *source;
	pthread_t thread;
	bool thread_started;
	volatile bool stop;
	volatile bool reconnect;
	volatile bool keyframe_wanted;

	pthread_mutex_t mutex; /* guards everything below */
	char selected_udid[64];
	bool clear_when_idle;
	char status[256];
	char connected_udid[64];
	char device_name[128];
	int width, height, fps, codec;
	double decoded_fps, latency_ms;
	uint64_t dropped;
	bool paused;

	/* connection thread only */
	int fd;
	struct tc_decoder *decoder;
	uint8_t *payload;
	size_t payload_capacity;
	uint64_t rtt_ns;
};

/* ---- Status ------------------------------------------------------------- */

/* Updates the status line and logs it when it changes, so connection problems show in the OBS log. */
static void set_status(struct typecam_source *ctx, const char *format, ...)
{
	char status[256];
	va_list args;
	va_start(args, format);
	vsnprintf(status, sizeof(status), format, args);
	va_end(args);

	pthread_mutex_lock(&ctx->mutex);
	bool changed = strcmp(ctx->status, status) != 0;
	strlcpy(ctx->status, status, sizeof(ctx->status));
	pthread_mutex_unlock(&ctx->mutex);
	if (changed)
		obs_log(LOG_INFO, "'%s': %s", obs_source_get_name(ctx->source), status);
}

static void clear_frame_if_needed(struct typecam_source *ctx)
{
	pthread_mutex_lock(&ctx->mutex);
	bool clear = ctx->clear_when_idle;
	pthread_mutex_unlock(&ctx->mutex);
	if (clear)
		obs_source_output_video(ctx->source, NULL);
}

static void short_udid(const char *udid, char *out, size_t size)
{
	size_t length = strlen(udid);
	snprintf(out, size, "…%s", length > 6 ? udid + length - 6 : udid);
}

/* ---- Socket I/O --------------------------------------------------------- */

static bool send_all(int fd, const void *buffer, size_t length)
{
	const uint8_t *p = buffer;
	while (length > 0) {
		ssize_t n = send(fd, p, length, 0);
		if (n < 0 && errno == EINTR)
			continue;
		if (n <= 0)
			return false;
		p += n;
		length -= (size_t)n;
	}
	return true;
}

static bool recv_all(int fd, void *buffer, size_t length)
{
	uint8_t *p = buffer;
	while (length > 0) {
		ssize_t n = recv(fd, p, length, 0);
		if (n < 0 && errno == EINTR)
			continue;
		if (n <= 0)
			return false;
		p += n;
		length -= (size_t)n;
	}
	return true;
}

static bool send_message(struct typecam_source *ctx, uint8_t type, const void *payload, size_t length)
{
	uint8_t header[TC_HEADER_SIZE];
	tc_write_header(header, type, 0, (uint32_t)length, 0);
	return send_all(ctx->fd, header, sizeof(header)) && (!length || send_all(ctx->fd, payload, length));
}

static bool send_json(struct typecam_source *ctx, uint8_t type, obs_data_t *data)
{
	const char *json = obs_data_get_json(data);
	return send_message(ctx, type, json, strlen(json));
}

static void sleep_interruptible(struct typecam_source *ctx, int ms)
{
	for (int waited = 0; waited < ms && !os_atomic_load_bool(&ctx->stop) &&
			     !os_atomic_load_bool(&ctx->reconnect);
	     waited += 100)
		os_sleep_ms(100);
}

/* ---- Connecting --------------------------------------------------------- */

/* Picks a device, claims it, and opens the tunnel. Returns true with ctx->fd set. */
static bool connect_device(struct typecam_source *ctx)
{
	struct usbmux_device devices[MAX_DEVICES];
	size_t count = usbmux_list_devices(devices, MAX_DEVICES);

	pthread_mutex_lock(&ctx->mutex);
	char selected[64];
	strlcpy(selected, ctx->selected_udid, sizeof(selected));
	pthread_mutex_unlock(&ctx->mutex);

	const struct usbmux_device *device = NULL;
	for (size_t i = 0; i < count; i++) {
		bool match = selected[0] ? strcmp(devices[i].udid, selected) == 0
					 : !tc_registry_claimed_by_other(devices[i].udid, ctx);
		if (match) {
			device = &devices[i];
			break;
		}
	}

	if (!device) {
		if (selected[0]) {
			char name[128];
			tc_registry_get_name(selected, name, sizeof(name), "the selected iPhone");
			set_status(ctx, "Waiting for %s. Connect it with a USB cable.", name);
		} else {
			set_status(ctx, count ? "All connected iPhones are in use by other TypeCam sources."
					      : "No iPhone connected. Connect one with a USB cable.");
		}
		return false;
	}
	if (!tc_registry_claim(device->udid, ctx)) {
		set_status(ctx, "This iPhone is in use by another TypeCam source.");
		return false;
	}

	int fd = usbmux_connect(device->device_id, TC_PORT);
	if (fd < 0) {
		tc_registry_release(ctx);
		set_status(ctx, "iPhone connected. Open TypeCam on it (and keep it unlocked).");
		return false;
	}

	struct timeval timeout = {.tv_sec = 3};
	setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
	setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));

	ctx->fd = fd;
	pthread_mutex_lock(&ctx->mutex);
	strlcpy(ctx->connected_udid, device->udid, sizeof(ctx->connected_udid));
	tc_registry_get_name(device->udid, ctx->device_name, sizeof(ctx->device_name), "iPhone");
	pthread_mutex_unlock(&ctx->mutex);
	return true;
}

/* ---- Message handling --------------------------------------------------- */

static bool handle_hello_ack(struct typecam_source *ctx, const uint8_t *payload, size_t length)
{
	char *json = bstrdup_n((const char *)payload, length);
	obs_data_t *ack = obs_data_create_from_json(json);
	bfree(json);
	if (!ack)
		return false;

	bool ok = obs_data_get_bool(ack, "ok");
	if (!ok) {
		const char *error = obs_data_get_string(ack, "error");
		obs_log(LOG_WARNING, "handshake rejected: %s", error);
		set_status(ctx, "Version mismatch: %s", error);
	} else {
		const char *name = obs_data_get_string(ack, "device_name");
		pthread_mutex_lock(&ctx->mutex);
		if (name[0])
			strlcpy(ctx->device_name, name, sizeof(ctx->device_name));
		tc_registry_set_name(ctx->connected_udid, ctx->device_name);
		pthread_mutex_unlock(&ctx->mutex);
		obs_log(LOG_INFO, "connected to %s (%s, app %s)", name, obs_data_get_string(ack, "model"),
			obs_data_get_string(ack, "app_version"));
	}
	obs_data_release(ack);
	return ok;
}

static bool handle_video_config(struct typecam_source *ctx, const uint8_t *p, size_t length)
{
	if (length < 13)
		return false;
	int codec = p[0];
	int width = tc_read_u16(p + 2), height = tc_read_u16(p + 4);
	int fps_num = tc_read_u16(p + 6), fps_den = tc_read_u16(p + 8);
	int rotation = tc_read_u16(p + 10);
	size_t count = p[12], offset = 13;

	const uint8_t *sets[8];
	size_t sizes[8];
	if (count == 0 || count > 8)
		return false;
	for (size_t i = 0; i < count; i++) {
		if (offset + 2 > length)
			return false;
		sizes[i] = tc_read_u16(p + offset);
		sets[i] = p + offset + 2;
		offset += 2 + sizes[i];
		if (offset > length)
			return false;
	}

	if (!tc_decoder_configure(ctx->decoder, codec, sets, sizes, count, rotation))
		return false;

	pthread_mutex_lock(&ctx->mutex);
	ctx->codec = codec;
	ctx->width = rotation % 180 ? height : width;
	ctx->height = rotation % 180 ? width : height;
	ctx->fps = fps_den ? fps_num / fps_den : fps_num;
	pthread_mutex_unlock(&ctx->mutex);
	return true;
}

static void handle_stream_state(struct typecam_source *ctx, const uint8_t *payload, size_t length)
{
	char *json = bstrdup_n((const char *)payload, length);
	obs_data_t *state = obs_data_create_from_json(json);
	bfree(json);
	if (!state)
		return;
	bool paused = strcmp(obs_data_get_string(state, "state"), "paused") == 0;
	pthread_mutex_lock(&ctx->mutex);
	ctx->paused = paused;
	pthread_mutex_unlock(&ctx->mutex);
	if (paused) {
		set_status(ctx, "Paused on the iPhone.");
		clear_frame_if_needed(ctx);
	}
	obs_data_release(state);
}

static bool read_message(struct typecam_source *ctx, struct tc_header *header)
{
	uint8_t raw[TC_HEADER_SIZE];
	if (!recv_all(ctx->fd, raw, sizeof(raw)) || !tc_read_header(raw, header))
		return false;
	if (header->length > ctx->payload_capacity) {
		ctx->payload = brealloc(ctx->payload, header->length);
		ctx->payload_capacity = header->length;
	}
	return !header->length || recv_all(ctx->fd, ctx->payload, header->length);
}

static void send_host_stats(struct typecam_source *ctx)
{
	obs_data_t *stats = obs_data_create();
	pthread_mutex_lock(&ctx->mutex);
	obs_data_set_double(stats, "decoded_fps", ctx->decoded_fps);
	obs_data_set_int(stats, "dropped_frames", (long long)ctx->dropped);
	obs_data_set_double(stats, "latency_ms", ctx->latency_ms);
	pthread_mutex_unlock(&ctx->mutex);
	obs_data_set_string(stats, "obs_version", obs_get_version_string());
	send_json(ctx, TC_HOST_STATS, stats);
	obs_data_release(stats);
}

/* Runs one connected session until disconnect, stop or a settings change. */
static void run_session(struct typecam_source *ctx)
{
	obs_data_t *hello = obs_data_create();
	obs_data_set_int(hello, "protocol_version", TC_PROTOCOL_VERSION);
	obs_data_set_string(hello, "client", "obs-typecam");
	obs_data_set_string(hello, "client_version", PLUGIN_VERSION);
	bool sent = send_json(ctx, TC_HELLO, hello);
	obs_data_release(hello);
	if (!sent)
		return;

	set_status(ctx, "Connecting…");
	bool live = false;
	uint64_t now = os_gettime_ns();
	uint64_t last_rx = now, last_tick = now;

	while (!os_atomic_load_bool(&ctx->stop) && !os_atomic_load_bool(&ctx->reconnect)) {
		if (os_atomic_set_bool(&ctx->keyframe_wanted, false))
			send_message(ctx, TC_KEYFRAME_REQUEST, NULL, 0);

		struct pollfd pfd = {.fd = ctx->fd, .events = POLLIN};
		int ready = poll(&pfd, 1, 100);
		now = os_gettime_ns();
		if (ready < 0 && errno != EINTR)
			return;

		if (ready > 0) {
			if (pfd.revents & (POLLHUP | POLLERR))
				return;
			struct tc_header header;
			if (!read_message(ctx, &header))
				return;
			last_rx = now;

			switch (header.type) {
			case TC_HELLO_ACK:
				if (!handle_hello_ack(ctx, ctx->payload, header.length)) {
					sleep_interruptible(ctx, 5000);
					return;
				}
				break;
			case TC_VIDEO_CONFIG:
				if (!handle_video_config(ctx, ctx->payload, header.length))
					send_message(ctx, TC_KEYFRAME_REQUEST, NULL, 0);
				break;
			case TC_VIDEO_FRAME:
				if (!tc_decoder_decode(ctx->decoder, ctx->payload, header.length, header.pts)) {
					pthread_mutex_lock(&ctx->mutex);
					ctx->dropped++;
					pthread_mutex_unlock(&ctx->mutex);
					send_message(ctx, TC_KEYFRAME_REQUEST, NULL, 0);
				} else if (!live) {
					live = true;
				}
				break;
			case TC_STREAM_STATE:
				handle_stream_state(ctx, ctx->payload, header.length);
				break;
			case TC_PING:
				send_message(ctx, TC_PONG, ctx->payload, header.length);
				break;
			case TC_PONG:
				if (header.length == 8) {
					uint64_t sent_at;
					memcpy(&sent_at, ctx->payload, 8);
					ctx->rtt_ns = now - sent_at;
				}
				break;
			default:
				break; /* unknown types are ignored */
			}
		}

		if (now - last_rx > LIVENESS_TIMEOUT_NS) {
			obs_log(LOG_INFO, "connection timed out");
			return;
		}

		if (now - last_tick >= TICK_NS) {
			double seconds = (double)(now - last_tick) / 1e9;
			last_tick = now;
			uint64_t stamp = now;
			send_message(ctx, TC_PING, &stamp, sizeof(stamp));

			uint32_t frames = tc_decoder_take_frame_count(ctx->decoder);
			pthread_mutex_lock(&ctx->mutex);
			ctx->decoded_fps = frames / seconds;
			/* One-way transit ≈ RTT/2, plus decode. Glass-to-OBS adds capture + encode on the phone. */
			ctx->latency_ms = (double)ctx->rtt_ns / 2e6 + tc_decoder_decode_ms(ctx->decoder);
			if (live && !ctx->paused)
				snprintf(ctx->status, sizeof(ctx->status), "Live: %s · %dx%d @ %.0f fps · %s · ~%.0f ms",
					 ctx->device_name, ctx->width, ctx->height, ctx->decoded_fps,
					 ctx->codec == TC_CODEC_HEVC ? "HEVC" : "H.264", ctx->latency_ms);
			pthread_mutex_unlock(&ctx->mutex);
			send_host_stats(ctx);
		}
	}
}

static void *connection_thread(void *data)
{
	struct typecam_source *ctx = data;
	os_set_thread_name("typecam-connection");

	while (!os_atomic_load_bool(&ctx->stop)) {
		os_atomic_set_bool(&ctx->reconnect, false);
		if (!connect_device(ctx)) {
			sleep_interruptible(ctx, 1000);
			continue;
		}

		run_session(ctx);

		close(ctx->fd);
		ctx->fd = -1;
		tc_registry_release(ctx);
		tc_decoder_reset(ctx->decoder);
		clear_frame_if_needed(ctx);
		pthread_mutex_lock(&ctx->mutex);
		ctx->connected_udid[0] = '\0';
		ctx->decoded_fps = 0;
		ctx->paused = false;
		pthread_mutex_unlock(&ctx->mutex);
		set_status(ctx, "Disconnected. Reconnecting…");
		sleep_interruptible(ctx, 500);
	}
	return NULL;
}

/* ---- obs_source_info ---------------------------------------------------- */

static const char *typecam_get_name(void *unused)
{
	UNUSED_PARAMETER(unused);
	return obs_module_text("TypeCamSource");
}

static void typecam_update(void *data, obs_data_t *settings)
{
	struct typecam_source *ctx = data;
	const char *udid = obs_data_get_string(settings, S_DEVICE);

	pthread_mutex_lock(&ctx->mutex);
	bool changed = strcmp(ctx->selected_udid, udid) != 0;
	strlcpy(ctx->selected_udid, udid, sizeof(ctx->selected_udid));
	ctx->clear_when_idle = strcmp(obs_data_get_string(settings, S_IDLE), IDLE_CLEAR) == 0;
	pthread_mutex_unlock(&ctx->mutex);

	obs_source_set_async_unbuffered(ctx->source, obs_data_get_bool(settings, S_UNBUFFERED));
	if (changed)
		os_atomic_set_bool(&ctx->reconnect, true);
}

static void *typecam_create(obs_data_t *settings, obs_source_t *source)
{
	struct typecam_source *ctx = bzalloc(sizeof(*ctx));
	ctx->source = source;
	ctx->fd = -1;
	pthread_mutex_init(&ctx->mutex, NULL);
	ctx->decoder = tc_decoder_create(source);
	strlcpy(ctx->status, "Starting…", sizeof(ctx->status));

	typecam_update(ctx, settings);
	os_atomic_set_bool(&ctx->reconnect, false);

	ctx->thread_started = pthread_create(&ctx->thread, NULL, connection_thread, ctx) == 0;
	return ctx;
}

static void typecam_destroy(void *data)
{
	struct typecam_source *ctx = data;
	os_atomic_set_bool(&ctx->stop, true);
	if (ctx->thread_started)
		pthread_join(ctx->thread, NULL);
	tc_registry_release(ctx);
	tc_decoder_destroy(ctx->decoder);
	bfree(ctx->payload);
	pthread_mutex_destroy(&ctx->mutex);
	bfree(ctx);
}

static void typecam_defaults(obs_data_t *settings)
{
	obs_data_set_default_string(settings, S_DEVICE, "");
	obs_data_set_default_bool(settings, S_UNBUFFERED, true);
	obs_data_set_default_string(settings, S_IDLE, IDLE_KEEP);
}

static bool refresh_clicked(obs_properties_t *props, obs_property_t *property, void *data);
static bool keyframe_clicked(obs_properties_t *props, obs_property_t *property, void *data);

static void fill_devices(obs_property_t *list, struct typecam_source *ctx)
{
	obs_property_list_clear(list);
	obs_property_list_add_string(list, obs_module_text("Device.Auto"), "");

	struct usbmux_device devices[MAX_DEVICES];
	size_t count = usbmux_list_devices(devices, MAX_DEVICES);
	bool selected_listed = false;
	for (size_t i = 0; i < count; i++) {
		char name[128], tail[16], label[200];
		tc_registry_get_name(devices[i].udid, name, sizeof(name), "iPhone");
		short_udid(devices[i].udid, tail, sizeof(tail));
		bool other = tc_registry_claimed_by_other(devices[i].udid, ctx);
		snprintf(label, sizeof(label), "%s (%s)%s", name, tail, other ? obs_module_text("Device.InUse") : "");
		obs_property_list_add_string(list, label, devices[i].udid);
		if (strcmp(devices[i].udid, ctx->selected_udid) == 0)
			selected_listed = true;
	}

	/* Keep a remembered device selectable while it's unplugged. */
	if (ctx->selected_udid[0] && !selected_listed) {
		char name[128], tail[16], label[200];
		tc_registry_get_name(ctx->selected_udid, name, sizeof(name), "iPhone");
		short_udid(ctx->selected_udid, tail, sizeof(tail));
		snprintf(label, sizeof(label), "%s (%s)%s", name, tail, obs_module_text("Device.NotConnected"));
		obs_property_list_add_string(list, label, ctx->selected_udid);
	}
}

static obs_properties_t *typecam_properties(void *data)
{
	struct typecam_source *ctx = data;
	obs_properties_t *props = obs_properties_create();

	obs_property_t *devices = obs_properties_add_list(props, S_DEVICE, obs_module_text("Device"),
							  OBS_COMBO_TYPE_LIST, OBS_COMBO_FORMAT_STRING);
	pthread_mutex_lock(&ctx->mutex);
	fill_devices(devices, ctx);
	char status[256];
	strlcpy(status, ctx->status, sizeof(status));
	pthread_mutex_unlock(&ctx->mutex);

	obs_properties_add_button2(props, S_REFRESH, obs_module_text("Refresh"), refresh_clicked, ctx);

	obs_property_t *info = obs_properties_add_text(props, S_STATUS, status, OBS_TEXT_INFO);
	obs_property_set_long_description(info, status);

	obs_properties_add_bool(props, S_UNBUFFERED, obs_module_text("LowLatency"));

	obs_property_t *idle = obs_properties_add_list(props, S_IDLE, obs_module_text("IdleBehavior"),
						       OBS_COMBO_TYPE_LIST, OBS_COMBO_FORMAT_STRING);
	obs_property_list_add_string(idle, obs_module_text("IdleBehavior.Keep"), IDLE_KEEP);
	obs_property_list_add_string(idle, obs_module_text("IdleBehavior.Clear"), IDLE_CLEAR);

	obs_properties_add_button2(props, S_KEYFRAME, obs_module_text("RequestKeyframe"), keyframe_clicked, ctx);
	return props;
}

/* Rebuilds the device list and status line. */
static bool refresh_clicked(obs_properties_t *props, obs_property_t *property, void *data)
{
	UNUSED_PARAMETER(property);
	struct typecam_source *ctx = data;
	pthread_mutex_lock(&ctx->mutex);
	fill_devices(obs_properties_get(props, S_DEVICE), ctx);
	char status[256];
	strlcpy(status, ctx->status, sizeof(status));
	pthread_mutex_unlock(&ctx->mutex);
	obs_property_set_description(obs_properties_get(props, S_STATUS), status);
	return true;
}

static bool keyframe_clicked(obs_properties_t *props, obs_property_t *property, void *data)
{
	UNUSED_PARAMETER(props);
	UNUSED_PARAMETER(property);
	struct typecam_source *ctx = data;
	os_atomic_set_bool(&ctx->keyframe_wanted, true);
	return false;
}

struct obs_source_info typecam_source_info = {
	.id = "typecam_source",
	.type = OBS_SOURCE_TYPE_INPUT,
	.output_flags = OBS_SOURCE_ASYNC_VIDEO | OBS_SOURCE_DO_NOT_DUPLICATE,
	.icon_type = OBS_ICON_TYPE_CAMERA,
	.get_name = typecam_get_name,
	.create = typecam_create,
	.destroy = typecam_destroy,
	.update = typecam_update,
	.get_defaults = typecam_defaults,
	.get_properties = typecam_properties,
};
