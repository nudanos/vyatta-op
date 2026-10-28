/*

Copyright (c) 2005-2008, Simon Howard

Permission to use, copy, modify, and/or distribute this software
for any purpose with or without fee is hereby granted, provided
that the above copyright notice and this permission notice appear
in all copies.

THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL
WARRANTIES WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE
AUTHOR BE LIABLE FOR ANY SPECIAL, DIRECT, INDIRECT, OR
CONSEQUENTIAL DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM
LOSS OF USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT,
NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF OR IN
CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

SPDX-License-Identifier: ISC

 */

#include <ctype.h>
#include <unistd.h> /* size_t */

#include "hash-string.h"

/* String hash function */

unsigned long string_hash(const void *string)
{
	/* This is the djb2 string hash function */

	unsigned long result = 5381;
	const unsigned char *p;

	p = (const unsigned char *) string;

	while (*p != '\0') {
		result = ((result << 5) ^ result ) ^ (*p);
		++p;
	}

	return result;
}

/* The same function, with a tolower on every character so that
 * case is ignored.  This code is duplicated for performance. */

unsigned long string_nocase_hash(const void *string)
{
	unsigned long result = 5381;
	const unsigned char *p;

	p = (const unsigned char *) string;

	while (*p != '\0') {
		result = ((result << 5) ^ result ) ^ tolower(*p);
		++p;
	}

	return result;
}

/* Buffer hash function */

unsigned long buffer_hash(const void *buf, size_t size)
{
	/* This is the djb2 string hash function */

	unsigned long result = 5381;
	const unsigned char *p, *e;

	p = (const unsigned char *) buf;
	e = p + size;

	while (p < e) {
		result = ((result << 5) ^ result ) ^ (*p);
		++p;
	}

	return result;
}
