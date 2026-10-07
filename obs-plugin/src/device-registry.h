/*
 * Process-wide bookkeeping shared by all TypeCam sources: which source owns which iPhone
 * (one stream per device), and the names devices reported in HELLO_ACK.
 */

#pragma once

#include <stdbool.h>
#include <stddef.h>

/* Claims `udid` for `owner`. Fails if another source holds it. */
bool tc_registry_claim(const char *udid, const void *owner);
void tc_registry_release(const void *owner);
/* True if a source other than `owner` holds `udid`. */
bool tc_registry_claimed_by_other(const char *udid, const void *owner);

void tc_registry_set_name(const char *udid, const char *name);
/* Writes the cached name, or `fallback` when the device hasn't connected yet. */
void tc_registry_get_name(const char *udid, char *out, size_t size, const char *fallback);
