#include "flick.h"

#include <stdlib.h>
#include <string.h>
#include <strings.h>

/* md4c-html's block callbacks are static, so its source is compiled as part of this file
 * (it is excluded from the target in Package.swift). The vendored file stays unmodified. */
#include "md4c-html.c"

typedef struct {
    MD_HTML html;        /* must stay first: md4c-html casts the userdata to MD_HTML* */
    flick_buf *out;
    int depth;           /* block nesting; 1 = directly inside the document */
    int in_html_block;
    int raw_open;        /* raw-HTML container tags opened by HTML blocks and not closed yet */
    int in_comment;

    /* FLICK_LINES: line numbers are only known once a block's first text arrives, so the opening
     * tag gets a fixed-width placeholder that is filled in then. */
    int lines;
    const char *src;
    size_t src_size;
    const char *scan;    /* newlines are counted up to here */
    unsigned scan_line;
    size_t mark;         /* offset of the pending placeholder digits; 0 = none */
    int mark_adjust;     /* -1 for fenced code, whose first text is on the line after the fence */
} flick_ctx;

#define FLICK_MARK " data-l=0000000"
#define FLICK_MARK_DIGITS 7

/* md4c calls this many times with small pieces; keep it a plain memcpy into one buffer. */
static void flick_append(const MD_CHAR *text, MD_SIZE size, void *userdata)
{
    flick_buf *b = (flick_buf *)userdata;
    if (b->failed)
        return;
    if (b->size + size > b->cap) {
        size_t cap = b->cap ? b->cap : 4096;
        while (cap < b->size + size)
            cap *= 2;
        char *p = (char *)realloc(b->data, cap);
        if (p == NULL) {
            b->failed = 1;
            return;
        }
        b->data = p;
        b->cap = cap;
    }
    memcpy(b->data + b->size, text, size);
    b->size += size;
}

static void flick_mark_boundary(flick_buf *b)
{
    if (b->failed)
        return;
    if (b->nbounds == b->bounds_cap) {
        size_t cap = b->bounds_cap ? b->bounds_cap * 2 : 256;
        size_t *p = (size_t *)realloc(b->bounds, cap * sizeof(size_t));
        if (p == NULL) {
            b->failed = 1;
            return;
        }
        b->bounds = p;
        b->bounds_cap = cap;
    }
    b->bounds[b->nbounds++] = b->size;
}

/* Container tags that raw HTML commonly opens in one block and closes in a later one,
 * e.g. <details> ... markdown ... </details>. Splitting between them would break nesting. */
static int flick_is_container_tag(const char *name, size_t len)
{
    static const char *tags[] = {
        "div", "details", "section", "article", "aside", "nav", "header", "footer", "main",
        "table", "thead", "tbody", "tfoot", "tr", "td", "th", "ul", "ol", "li", "dl", "dd", "dt",
        "blockquote", "figure", "figcaption", "center", "form", "fieldset", "p", NULL
    };
    for (int i = 0; tags[i]; i++) {
        if (strlen(tags[i]) == len && strncasecmp(tags[i], name, len) == 0)
            return 1;
    }
    return 0;
}

static void flick_scan_raw_html(flick_ctx *ctx, const MD_CHAR *text, MD_SIZE size)
{
    for (MD_SIZE i = 0; i < size; i++) {
        if (ctx->in_comment) {
            if (text[i] == '-' && i + 2 < size && text[i + 1] == '-' && text[i + 2] == '>') {
                ctx->in_comment = 0;
                i += 2;
            }
            continue;
        }
        if (text[i] != '<')
            continue;
        if (i + 3 < size && text[i + 1] == '!' && text[i + 2] == '-' && text[i + 3] == '-') {
            ctx->in_comment = 1;
            i += 3;
            continue;
        }
        MD_SIZE j = i + 1;
        int closing = (j < size && text[j] == '/');
        if (closing)
            j++;
        MD_SIZE start = j;
        while (j < size && ((text[j] >= 'a' && text[j] <= 'z') || (text[j] >= 'A' && text[j] <= 'Z') || (text[j] >= '0' && text[j] <= '9')))
            j++;
        if (j == start || !flick_is_container_tag(text + start, j - start))
            continue;
        if (closing) {
            if (ctx->raw_open > 0)
                ctx->raw_open--;
        } else {
            /* Skip self-closing forms like <div/>. */
            MD_SIZE k = j;
            while (k < size && text[k] != '>')
                k++;
            if (!(k > 0 && k < size && text[k - 1] == '/'))
                ctx->raw_open++;
        }
    }
}

/* Inserts the placeholder attribute into the first tag written since `tag_start`. */
static void flick_open_mark(flick_ctx *ctx, size_t tag_start, int adjust)
{
    flick_buf *b = ctx->out;
    char *gt = (char *)memchr(b->data + tag_start, '>', b->size - tag_start);
    if (gt == NULL)
        return;
    size_t at = (size_t)(gt - b->data);
    size_t n = sizeof(FLICK_MARK) - 1;
    size_t old_size = b->size;
    flick_append(FLICK_MARK, (MD_SIZE)n, b); /* grows the buffer; the bytes are moved into place below */
    if (b->failed)
        return;
    memmove(b->data + at + n, b->data + at, old_size - at);
    memcpy(b->data + at, FLICK_MARK, n);
    ctx->mark = at + n - FLICK_MARK_DIGITS;
    ctx->mark_adjust = adjust;
}

static void flick_fill_mark(flick_ctx *ctx, const MD_CHAR *text)
{
    if (text < ctx->src || text >= ctx->src + ctx->src_size)
        return; /* synthetic text (e.g. a replacement character), not a position in the source */
    if (text < ctx->scan) {
        /* Footnote definitions are rendered at the end but live earlier in the file. */
        ctx->scan = ctx->src;
        ctx->scan_line = 1;
    }
    for (const char *p = ctx->scan; p < text;) {
        const char *nl = (const char *)memchr(p, '\n', (size_t)(text - p));
        if (nl == NULL)
            break;
        ctx->scan_line++;
        p = nl + 1;
    }
    ctx->scan = text;

    long line = (long)ctx->scan_line + ctx->mark_adjust;
    if (line >= 1 && line <= 9999999) {
        char digits[FLICK_MARK_DIGITS + 1];
        snprintf(digits, sizeof(digits), "%07ld", line);
        memcpy(ctx->out->data + ctx->mark, digits, FLICK_MARK_DIGITS);
    }
    ctx->mark = 0;
}

static int flick_enter_block(MD_BLOCKTYPE type, void *detail, void *userdata)
{
    flick_ctx *ctx = (flick_ctx *)userdata;
    int top_level = (ctx->depth == 1);
    size_t tag_start = ctx->out->size;
    ctx->depth++;
    if (type == MD_BLOCK_HTML)
        ctx->in_html_block = 1;
    int rc = enter_block_callback(type, detail, userdata);
    if (ctx->lines && top_level && type != MD_BLOCK_HTML && ctx->out->size > tag_start) {
        int fenced = (type == MD_BLOCK_CODE && ((MD_BLOCK_CODE_DETAIL *)detail)->fence_char != 0);
        flick_open_mark(ctx, tag_start, fenced ? -1 : 0);
    }
    return rc;
}

static int flick_leave_block(MD_BLOCKTYPE type, void *detail, void *userdata)
{
    flick_ctx *ctx = (flick_ctx *)userdata;
    int rc = leave_block_callback(type, detail, userdata);
    if (type == MD_BLOCK_HTML)
        ctx->in_html_block = 0;
    if (--ctx->depth == 1) {
        ctx->mark = 0; /* a block without text (e.g. <hr>) keeps line 0, meaning unknown */
        if (ctx->raw_open == 0 && !ctx->in_comment)
            flick_mark_boundary(ctx->out);
    }
    return rc;
}

static int flick_text(MD_TEXTTYPE type, const MD_CHAR *text, MD_SIZE size, void *userdata)
{
    flick_ctx *ctx = (flick_ctx *)userdata;
    if (ctx->mark)
        flick_fill_mark(ctx, text);
    if (type == MD_TEXT_HTML && ctx->in_html_block)
        flick_scan_raw_html(ctx, text, size);
    return text_callback(type, text, size, userdata);
}

int flick_render_html(const char *input, size_t size, flick_buf *out, unsigned flags)
{
    memset(out, 0, sizeof(*out));
    /* HTML is usually ~1.2-1.6x the source; reserve once to avoid most reallocs. */
    out->cap = size + size / 2 + 1024;
    out->data = (char *)malloc(out->cap);
    if (out->data == NULL)
        return -1;

    flick_ctx ctx;
    memset(&ctx, 0, sizeof(ctx));
    ctx.html.process_output = flick_append;
    ctx.html.userdata = out;
    ctx.html.flags = MD_HTML_FLAG_SKIP_UTF8_BOM;
    ctx.out = out;
    for (int i = 0; i < 256; i++) {
        unsigned char ch = (unsigned char)i;
        if (strchr("\"&'<>", ch) != NULL)
            ctx.html.escape_map[i] |= NEED_HTML_ESC_FLAG;
        if (!ISALNUM(ch) && strchr("~-_.+!*(),%#@?=;:/$", ch) == NULL)
            ctx.html.escape_map[i] |= NEED_URL_ESC_FLAG;
    }

    MD_PARSER parser = {
        0,
        MD_DIALECT_GITHUB | MD_FLAG_LATEXMATHSPANS | MD_FLAG_HIGHLIGHT,
        flick_enter_block,
        flick_leave_block,
        enter_span_callback,
        leave_span_callback,
        flick_text,
        debug_log_callback,
        NULL
    };

    /* Same BOM handling as md_html() with MD_HTML_FLAG_SKIP_UTF8_BOM. */
    if (size >= 3 && memcmp(input, "\xef\xbb\xbf", 3) == 0) {
        input += 3;
        size -= 3;
    }

    ctx.lines = (flags & FLICK_LINES) != 0;
    ctx.src = input;
    ctx.src_size = size;
    ctx.scan = input;
    ctx.scan_line = 1;

    int rc = md_parse(input, (MD_SIZE)size, &parser, &ctx);
    return (rc != 0 || out->failed) ? -1 : 0;
}

void flick_buf_free(flick_buf *buf)
{
    free(buf->data);
    free(buf->bounds);
    memset(buf, 0, sizeof(*buf));
}
