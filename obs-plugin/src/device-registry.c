#include "device-registry.h"

#include <pthread.h>
#include <string.h>

#define MAX_DEVICES 16

struct entry {
	char udid[64];
	char name[128];
	const void *owner;
};

static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static struct entry entries[MAX_DEVICES];

/* Must hold `lock`. Creates the entry when `create` is set and there's room. */
static struct entry *find(const char *udid, bool create)
{
	struct entry *empty = NULL;
	for (size_t i = 0; i < MAX_DEVICES; i++) {
		if (strcmp(entries[i].udid, udid) == 0)
			return &entries[i];
		if (!empty && entries[i].udid[0] == '\0')
			empty = &entries[i];
	}
	if (create && empty)
		strlcpy(empty->udid, udid, sizeof(empty->udid));
	return create ? empty : NULL;
}

bool tc_registry_claim(const char *udid, const void *owner)
{
	pthread_mutex_lock(&lock);
	struct entry *e = find(udid, true);
	bool ok = e && (!e->owner || e->owner == owner);
	if (ok)
		e->owner = owner;
	pthread_mutex_unlock(&lock);
	return ok;
}

void tc_registry_release(const void *owner)
{
	pthread_mutex_lock(&lock);
	for (size_t i = 0; i < MAX_DEVICES; i++) {
		if (entries[i].owner == owner)
			entries[i].owner = NULL;
	}
	pthread_mutex_unlock(&lock);
}

bool tc_registry_claimed_by_other(const char *udid, const void *owner)
{
	pthread_mutex_lock(&lock);
	struct entry *e = find(udid, false);
	bool claimed = e && e->owner && e->owner != owner;
	pthread_mutex_unlock(&lock);
	return claimed;
}

void tc_registry_set_name(const char *udid, const char *name)
{
	pthread_mutex_lock(&lock);
	struct entry *e = find(udid, true);
	if (e)
		strlcpy(e->name, name, sizeof(e->name));
	pthread_mutex_unlock(&lock);
}

void tc_registry_get_name(const char *udid, char *out, size_t size, const char *fallback)
{
	pthread_mutex_lock(&lock);
	struct entry *e = find(udid, false);
	strlcpy(out, e && e->name[0] ? e->name : fallback, size);
	pthread_mutex_unlock(&lock);
}
