#ifndef FLICK_H
#define FLICK_H

#include <stddef.h>

/* Output of flick_render_html(). Free with flick_buf_free(). */
typedef struct {
    char *data;
    size_t size;
    size_t cap;
    int failed;
    /* Offsets in `data` where a top-level block ends and the HTML can be split into
     * independently parseable pieces (never inside a raw-HTML container such as <details>). */
    size_t *bounds;
    size_t nbounds;
    size_t bounds_cap;
} flick_buf;

/* Adds data-l="<line>" (1-based source line) to the opening tag of every top-level block,
 * so a preview can be scrolled in step with a source editor. */
#define FLICK_LINES 0x1

/* Renders GitHub-flavoured Markdown (plus $math$) to HTML in a single pass.
 * Returns 0 on success, -1 on parse or allocation failure. */
int flick_render_html(const char *input, size_t size, flick_buf *out, unsigned flags);

void flick_buf_free(flick_buf *buf);

#endif
