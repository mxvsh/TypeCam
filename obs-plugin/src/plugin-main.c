/*
 * obs-typecam — iPhone camera source for OBS over USB.
 * Copyright (C) 2026 Monawwar Abdullah <xencodes@icloud.com>
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 */

#include <obs-module.h>
#include <plugin-support.h>

OBS_DECLARE_MODULE()
OBS_MODULE_USE_DEFAULT_LOCALE(PLUGIN_NAME, "en-US")

extern struct obs_source_info typecam_source_info;

MODULE_EXPORT const char *obs_module_description(void)
{
	return "Use an iPhone running TypeCam as a wired, low-latency camera.";
}

bool obs_module_load(void)
{
	obs_register_source(&typecam_source_info);
	obs_log(LOG_INFO, "plugin loaded (version %s)", PLUGIN_VERSION);
	return true;
}

void obs_module_unload(void)
{
	obs_log(LOG_INFO, "plugin unloaded");
}
