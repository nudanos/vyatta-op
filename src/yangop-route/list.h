/* Copyright (c) 2019, AT&T Intellectual Property. All rights reserved.
 *
 * Copyright (c) 2014-2015 by Brocade Communications Systems, Inc.
 * All rights reserved.
 *
 * SPDX-License-Identifier: GPL-2.0-only
 */

#ifndef LIST_H_
#define LIST_H_

#include <stddef.h>

#define container_of(ptr, type, member) ({                      \
        const typeof( ((type *)0)->member ) *__mptr = (ptr);    \
        (type *)( (char *)__mptr - offsetof(type,member) );})


struct list {
	struct list *next;
	struct list *prev;
};

static inline void list_init(struct list *l)
{
	l->next = l->prev = l;
}

static inline int list_empty(const struct list *l)
{
	return l->next == l;
}

static inline int list_last(const struct list *e, const struct list *l)
{
        return e->next == l;
}

static inline void list_add_tail(struct list *new, struct list *l)
{
	new->next = l;
	new->prev = l->prev;
	l->prev->next = new;
	l->prev = new;
}

static inline void list_del(struct list *del)
{
        del->next->prev = del->prev;
        del->prev->next = del->next;
	list_init(del);
}

static inline struct list *list_del_head(struct list *l)
{
	struct list *del = l->next;
	list_del(del);
	return del;
}


#define list_foreach(i, l) for (i = (l)->next; i != (l); i = i->next)

#define list_foreach_del(i, t, l) \
	for (i = (l)->next, t = i->next; i != (l); i = t, t = i->next)

#endif
