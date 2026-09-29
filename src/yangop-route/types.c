/* Copyright (c) 2019, AT&T Intellectual Property. All rights reserved.
 *
 * Copyright (c) 2015 by Brocade Communications Systems, Inc.
 * All rights reserved.
 *
 * SPDX-License-Identifier: GPL-2.0-only
 */

#include <arpa/inet.h>
#include <errno.h>
#include <linux/limits.h>
#include <net/if.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#include <jansson.h>

#include "types.h"

#define PFXLEN_IPV4_HOST (32U)
#define PFXLEN_IPV6_HOST (128U)

static int ip_any(int family, const void *addr, unsigned int prefixlen)
{
	int result;

	if (family == AF_INET) {
		struct in_addr any = { 0 };
		if (prefixlen != PFXLEN_IPV4_HOST)
			return 0;
		result = memcmp(addr, &any, sizeof(struct in_addr)) == 0;
	} else {
		if (prefixlen != PFXLEN_IPV6_HOST)
			return 0;
		result = memcmp(addr, &in6addr_any, sizeof(struct in6_addr)) == 0;
	}
	return result;
}


static json_t *address_json(int family, const void *addr, unsigned int prefixlen)
{
	char ip[INET6_ADDRSTRLEN + 5]; /* + "/123" + \0 */
	unsigned int host_len = (family == AF_INET6)
		? PFXLEN_IPV6_HOST : PFXLEN_IPV4_HOST;

	inet_ntop(family, addr, ip, sizeof(ip));
	if (prefixlen && host_len != prefixlen) {
		size_t n = strlen(ip);
		snprintf(ip + n, sizeof(ip) - n, "/%u", prefixlen);
	}
	return json_string(ip);
}

struct path *path_create(void)
{
	struct path *p;

	p =  calloc(1, sizeof(struct path));
	if (!p)
		return NULL;
	list_init(&p->path);
	return p;
}

void path_destroy(void *p)
{
	free(p);
}

static json_t *path_json(const struct path *p, unsigned int entry)
{

	json_t *jpath = json_object();
	json_t *jentry = json_integer(entry);
	json_object_set_new(jpath, "entry", jentry);

	if (p->flags & PATHF_IFIDX) {
		char name[IFNAMSIZ];
		if (if_indextoname(p->ifidx, name) == NULL)
			snprintf(name, sizeof(name), "if%d", p->ifidx);
		json_t *jdevice = json_string(name);
		json_object_set_new(jpath, "device", jdevice);
	}

	if (p->flags & PATHF_NEXTHOP) {
		json_t *jnexthop = address_json(p->af, &p->nexthop, 0);
		json_object_set_new(jpath, "next-hop", jnexthop);
	}

	return jpath;
}

struct route *route_create(void)
{
	struct route *r;

	r =  calloc(1, sizeof(struct route));
	if (!r)
		return NULL;
	list_init(&r->paths);
	return r;
}

void route_destroy(void *b)
{
	struct route *r = b;
	if (!r)
		return;
	while (!list_empty(&r->paths)) {
		struct path *p;
		struct list *l = list_del_head(&r->paths);
		p = container_of(l, struct path, path);
		path_destroy(p);
	}
	free(r);
}

json_t *route_json(const struct route *r, const char *ns __attribute__((unused)))
{
	struct list *item;
	struct path *p;
	unsigned int entry = 1;

	json_t *jroute = json_object();

	json_t *jdest = address_json(r->af, &r->dest, r->pfxlen);
	json_object_set_new(jroute, "destination", jdest);

	/* src address should not be ANY address */
	if (r->srclen && !ip_any(r->af, &r->src, r->srclen)) {
		json_t *jsrc = address_json(r->af, &r->src, r->srclen);
		json_object_set_new(jroute, "source", jsrc);
	}

	json_t *jpaths = json_array();
	list_foreach(item, &r->paths) {
		p = container_of(item, struct path, path);
		json_t *jpath = path_json(p, entry++);
		json_array_append_new(jpaths, jpath);
	}
	if (json_array_size(jpaths))
		json_object_set_new(jroute, "path", jpaths);

	return jroute;
}
