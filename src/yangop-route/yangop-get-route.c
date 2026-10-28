/*
 * Copyright (c) 2019, AT&T Intellectual Property. All rights reserved.
 *
 * Copyright (c) 2015 by Brocade Communications Systems, Inc.
 * All rights reserved.
 *
 * SPDX-License-Identifier: GPL-2.0-only
 */

#include <arpa/inet.h>
#include <errno.h>
#include <ifaddrs.h>
#include <limits.h>
#include <net/if.h>
#include <netinet/in.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include <libmnl/libmnl.h>
#include <linux/rtnetlink.h>

#include "hash-string.h"
#include "hash-table.h"
#include "types.h"

struct destroute {
	const char *arg;
	struct in6_addr as;
	int addrlen;
	int family;
	unsigned int prefixlen;
};

static uint32_t nl_seq;
static int debug;
static HashTable *route_table;

static void Pdebug(const char *fmt, ...) __attribute__ ((format (printf, 1, 2)));

static inline void Perror(const char *s)
{
	if (debug)
		perror(s);
}

static void Pdebug(const char *fmt, ...)
{
	if (debug) {
		va_list args;

		va_start(args, fmt);
		vfprintf(stderr, fmt, args);
		va_end(args);
	}
}

static void *addr_copy(void *dest, const void *src, int family)
{
	size_t size;

	if (family == AF_INET) {
		size_t unused = sizeof(struct in6_addr) - sizeof(struct in_addr);
		size = sizeof(struct in_addr);
		memset((char *)dest + size, 0, unused);
	} else
		size = sizeof(struct in6_addr);
	return memcpy(dest, src, size);
}

// cppcheck-suppress constParameterCallback ; reason: the hash table's HashTableHashFunc type fixes the signature
static unsigned long addr_hash(void *addr)
{
	return buffer_hash(addr, sizeof(struct in6_addr));
}

// cppcheck-suppress constParameterCallback ; reason: the hash table's HashTableEqualFunc type fixes the signature
static int addr_equal(void *addr1, void *addr2)
{
	return memcmp(addr1, addr2, sizeof(struct in6_addr)) == 0;
}

static int get_prefix(unsigned int *prefix, const char *arg)
{
	unsigned long pfx;
	char *ptr;

	if (!arg || !*arg)
		return -1;

	pfx = strtoul(arg, &ptr, 0);

	/* empty string or trailing non-digits */
	if (!ptr || ptr == arg || *ptr) {
		errno = EINVAL;
		return -1;
	}

	/* overflow */
	if (pfx == ULONG_MAX && errno == ERANGE)
		return -1;

	/* out side range of unsigned */
	if (pfx > UINT_MAX)
		return -1;

	*prefix = pfx;
	return 0;
}

static int get_destroute(struct destroute *dr, const char *addr, int family)
{
	int result = -1;
	int parsefamily = AF_INET;
	char *sep;
	int alen;

	if (strchr(addr, ':')) {
		parsefamily = AF_INET6;
		alen = sizeof(struct in6_addr);
		dr->prefixlen = 128;
	} else {
		alen = sizeof(struct in_addr);
		dr->prefixlen = 32;
	}
	if (parsefamily != family) {
		errno = EINVAL;
		return -1;
	}
	dr->family = family;

	if ((sep = strchr(addr, '/')))
		*sep = '\0';

	if (inet_pton(dr->family, addr, &dr->as) <= 0)
		goto error;

	if (sep) {
		unsigned int plen;
		if (get_prefix(&plen, sep + 1) || (plen > dr->prefixlen))
			goto error;
		dr->prefixlen = plen;
	}
	dr->addrlen = alen;
	dr->arg = addr;
	result = 0;
error:
	if (sep)
		*sep = '/';
	return result;
}

static char *if_addrtoname(int family, void *addr)
{
	struct ifaddrs *addrs, *iap;
	char *name = NULL;

	getifaddrs(&addrs);
	for (iap = addrs; iap != NULL; iap = iap->ifa_next) {
		if (iap->ifa_addr && iap->ifa_addr->sa_family == family) {
			struct in6_addr if_addr;
			const void *ifaddr;
			if (family == AF_INET)
				ifaddr = &((struct sockaddr_in *)iap->ifa_addr)->sin_addr;
			else
				ifaddr = &((struct sockaddr_in6 *)iap->ifa_addr)->sin6_addr;
			addr_copy(&if_addr, ifaddr, family);
			if (addr_equal(addr, &if_addr)) {
				name = strdup(iap->ifa_name);
				break;
			}
		}
	}
	freeifaddrs(addrs);
	return name;
}


static int route_table_json(const char *ns)
{
	const struct route *r;
	HashTableIterator iter;
	int result = EXIT_FAILURE;

	hash_table_iterate(route_table, &iter);

	json_t *jroute_table = json_array();
	if (!jroute_table)
		return EXIT_FAILURE;

	while ((r = hash_table_iter_next(&iter)) != HASH_TABLE_NULL) {
		json_t *jroute = route_json(r, ns);
		json_array_append_new(jroute_table, jroute);
	}

	if (json_array_size(jroute_table)) {
		json_t *jobj = json_object();
		if (!jobj)
			goto error;
		if (json_object_set_new(jobj, "route", jroute_table)) {
			free(jobj);
			goto error;
		}
		jroute_table = NULL;
		char *json = json_dumps(jobj, JSON_PRESERVE_ORDER | JSON_COMPACT);
		if (!json) {
			free(jobj);
			goto error;
		}
		fputs(json, stdout);
		free(json);
		free(jobj);
	}
	result = EXIT_SUCCESS;
error:
	free(jroute_table);
	return result;
}

static int route_table_add(struct route *nr)
{
	struct route *er = hash_table_lookup(route_table, &nr->dest);
	if (er) {
		struct list *entry, *tmp;
		list_foreach_del(entry, tmp, &nr->paths) {
			struct path *p = container_of(entry, struct path, path);
			list_del(&p->path);
			list_add_tail(&p->path, &er->paths);
		}
		route_destroy(nr);
	} else {
		if (!hash_table_insert(route_table, &nr->dest, nr)) {
			Pdebug("hash_table_insert failed");
			return -1;
		}
	}
	return 0;
}

static int route_attr_cb(const struct nlattr *attr, void *data)
{
	const struct nlattr **tb = (const struct nlattr **)data;
	int type = mnl_attr_get_type(attr);

	if (mnl_attr_type_valid(attr, RTA_MAX) < 0) {
		Pdebug("Skipping unknown attr type %d", type);
		return MNL_CB_OK;
	}

	switch (type) {
	case RTA_TABLE:
	case RTA_OIF:
	case RTA_FLOW:
		if (mnl_attr_validate(attr, MNL_TYPE_U32) < 0) {
			Pdebug("Invalid route attribute %d", type);
			return MNL_CB_ERROR;
		}
		break;
	}
	tb[type] = attr;
	return MNL_CB_OK;
}

static void set_path_idx(struct path *p, int family, const struct rtmsg *rm, struct nlattr *tb[])
{
	void *addr;

	p->af = family;
	if ((rm->rtm_table == RT_TABLE_LOCAL) && tb[RTA_PREFSRC]) {
		addr = mnl_attr_get_payload(tb[RTA_PREFSRC]);
		char *name = if_addrtoname(family, addr);
		if (name) {
			int idx = if_nametoindex(name);
			if (idx != 0) {
				p->ifidx = idx;
				p->flags |= PATHF_IFIDX;
			}
			free(name);
		}
	} else if (tb[RTA_OIF]) {
		p->ifidx = mnl_attr_get_u32(tb[RTA_OIF]);
		p->flags |= PATHF_IFIDX;
	}
}

static struct route *process_route(const struct rtmsg *rm, struct nlattr *tb[])
{
	const void *addr;
	struct path *p;
	struct route *r = route_create();

	if (!r) {
		Pdebug("route_create");
		return NULL;
	}

	r->af = rm->rtm_family;
	r->pfxlen = rm->rtm_dst_len;
	if (tb[RTA_DST]) {
		addr = mnl_attr_get_payload(tb[RTA_DST]);
		addr_copy(&r->dest, addr, r->af);
	} else {
		/* r->dest is zero initialized at create time */
		if (r->af == AF_INET6)
			addr_copy(&r->dest, &in6addr_any, r->af);
	}

	if (tb[RTA_SRC]) {
		r->srclen = rm->rtm_src_len;
		addr = mnl_attr_get_payload(tb[RTA_SRC]);
		addr_copy(&r->src, addr, r->af);
	}


	if (tb[RTA_MULTIPATH]) {
		void *vnhp;

		mnl_attr_for_each_nested(vnhp, tb[RTA_MULTIPATH]) {
			struct rtnexthop *nhp = vnhp;
			p = path_create();
			if (!p) {
				Pdebug("path_create");
				goto error;
			}
			set_path_idx(p, r->af, rm, tb);
			if (nhp->rtnh_len > sizeof(*nhp)) {
				struct nlattr *ntb[RTA_MAX + 1] = { NULL };
				mnl_attr_parse_payload((struct nlattr *)RTNH_DATA(nhp),
						       nhp->rtnh_len - sizeof(*nhp),
						       route_attr_cb, ntb);
				if (ntb[RTA_GATEWAY]) {
					addr = mnl_attr_get_payload(ntb[RTA_GATEWAY]);
					addr_copy(&p->nexthop, addr, p->af);
					p->flags |= PATHF_NEXTHOP;
				}
			}
			list_add_tail(&p->path, &r->paths);
		}
	} else {
		p = path_create();
		if (!p) {
			Pdebug("path_create");
			goto error;
		}
		set_path_idx(p, r->af, rm, tb);
		if (tb[RTA_GATEWAY]) {
			addr = mnl_attr_get_payload(tb[RTA_GATEWAY]);
			addr_copy(&p->nexthop, addr, p->af);
			p->flags |= PATHF_NEXTHOP;
		}
		list_add_tail(&p->path, &r->paths);
	}
	return r;
error:
	path_destroy(p);
	route_destroy(r);
	return NULL;
}


static int process_rtnl(const struct nlmsghdr *nlh, void *arg)
{
	struct route *r;
	const struct destroute *rt = arg;
	struct nlattr *tb[RTA_MAX + 1] = { NULL };
	struct rtmsg *rm = mnl_nlmsg_get_payload(nlh);

	/* rt is only set for specific route request */
	if (rt && (rm->rtm_type == RTN_UNREACHABLE)) {
		/* IPv6 unreach is handled here */
		errno = ENETUNREACH;
		return MNL_CB_ERROR;
	}

	if (!rt && (rm->rtm_table != RT_TABLE_MAIN)) {
		Pdebug("Skipping table %d\n", rm->rtm_table);
		return MNL_CB_OK;
	}

	if (mnl_attr_parse(nlh, sizeof(*rm), route_attr_cb, tb) != MNL_CB_OK) {
		fprintf(stderr, "Unparsable route attributes");
		return MNL_CB_ERROR;
	}

	r = process_route(rm, tb);
	if (r)
		route_table_add(r);
	return MNL_CB_OK;
}

static struct mnl_socket *nl_init(void)
{
	struct mnl_socket *nl = mnl_socket_open(NETLINK_ROUTE);
	if (!nl) {
		Perror("mnl_socket_open");
		return NULL;
	}

	if (mnl_socket_bind(nl, 0, MNL_SOCKET_AUTOPID) < 0) {
		Perror("mnl_socket_bind");
		return NULL;
	}
	return nl;
}

static int get_route_table(int family)
{
	int result = EXIT_FAILURE;
	unsigned int portid;
	char buf[MNL_SOCKET_BUFFER_SIZE];
	struct nlmsghdr *nlh;
	struct rtmsg *rtm;
	ssize_t len;

	struct mnl_socket *nl = nl_init();
	if (!nl) {
		Perror("nl_init");
		return EXIT_FAILURE;
	}

	nlh = mnl_nlmsg_put_header(buf);
	nlh->nlmsg_type = RTM_GETROUTE;
	nlh->nlmsg_flags = NLM_F_REQUEST | NLM_F_DUMP;
	nlh->nlmsg_seq = ++nl_seq;
	rtm = mnl_nlmsg_put_extra_header(nlh, sizeof(struct rtmsg));
	rtm->rtm_family = family;
	portid = mnl_socket_get_portid(nl);

	if (mnl_socket_sendto(nl, nlh, nlh->nlmsg_len) < 0) {
		Perror("mnl_socket_send");
		goto error;
	}

	while ((len = mnl_socket_recvfrom(nl, buf, sizeof(buf))) > 0) {
		int ret = mnl_cb_run(buf, len, nl_seq, portid, process_rtnl, NULL);
		if (ret <= MNL_CB_STOP)
			break;
	}
	if (len == -1) {
		Perror("mnl_socket_recvfrom");
		goto error;
	}
	result = EXIT_SUCCESS;
error:
        mnl_socket_close(nl);
	return result;
}

static int get_route(struct destroute *dr)
{
	int result = EXIT_FAILURE;
	char buf[MNL_SOCKET_BUFFER_SIZE];
	unsigned int portid;
	struct nlmsghdr *nlh;
	struct rtmsg *rtm;
	ssize_t len;
	struct mnl_socket *nl = nl_init();
	if (!nl) {
		Perror("nl_init");
		return EXIT_FAILURE;
	}

	nlh = mnl_nlmsg_put_header(buf);
	nlh->nlmsg_type = RTM_GETROUTE;
	nlh->nlmsg_flags = NLM_F_REQUEST;
	nlh->nlmsg_seq = ++nl_seq;

	rtm = mnl_nlmsg_put_extra_header(nlh, sizeof(struct rtmsg));
	mnl_attr_put(nlh, RTA_DST, dr->addrlen, &dr->as);
	rtm->rtm_dst_len = dr->prefixlen;
	rtm->rtm_family = dr->family;
	portid = mnl_socket_get_portid(nl);

	if (mnl_socket_sendto(nl, nlh, nlh->nlmsg_len) < MNL_CB_STOP) {
		Perror("mnl_socket_send");
		goto error;
	}

	len = mnl_socket_recvfrom(nl, buf, sizeof(buf));
	if (len < 0) {
		Perror("mnl_socket_recvfrom");
		goto error;
	}

	/* IPv4 unreach will not call process_rtnl */
	errno = 0;
	if (mnl_cb_run(buf, len, nl_seq, portid, process_rtnl, dr) < 0) {
		fprintf(stderr, "%s", strerror(errno));
		if (dr->arg)
			fprintf(stderr, ": %s", dr->arg);
		goto error;
	}
	result = EXIT_SUCCESS;
error:
	mnl_socket_close(nl);
	return result;
}

int main (int argc, char **argv) {
	int opt;
	int family = AF_INET;
	const char *rt = NULL;
	const char *ns = "urn:vyatta.com:mgmt:vyatta-op";
	int result;

	while ((opt = getopt(argc, argv, ":6dn:r:")) != -1) {
		switch (opt) {
		case '6':
			family = AF_INET6;
			break;
		case 'd':
			++debug;
			break;
		case 'n':
			ns = optarg;
			break;
		case 'r':
			rt = optarg;
			break;
		case ':':
			fprintf(stderr, "Option %c is missing a parameter; ignoring\n", optopt);
			break;
		case '?':
		default:
			fprintf(stderr, "Unknown option %c; ignoring\n", optopt);
			break;
		}
	}

	route_table = hash_table_new(addr_hash, addr_equal);
	if (!route_table) {
		Pdebug("hash_table_new failed");
		exit(EXIT_FAILURE);
	}
	hash_table_register_free_functions(route_table, NULL, route_destroy);

	if (rt) {
		struct destroute dest;
		memset(&dest, 0, sizeof(dest));
		if (get_destroute(&dest, rt, family)) {
			fprintf(stderr, "Invalid destination specified; %s\n", rt);
			result = EXIT_FAILURE;
			goto error;
		}
		result = get_route(&dest);
	} else
		result = get_route_table(family);

	if (result == 0)
		result = route_table_json(ns);

error:
	hash_table_free(route_table);
	exit(result);
}
