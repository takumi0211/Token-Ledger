#include "ArchiveReader.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dlfcn.h>

/* Zstd's stable streaming ABI; the vendor library is loaded explicitly, never from cwd. */
typedef struct { const void *src; size_t size, pos; } Input;
typedef struct { void *dst; size_t size, pos; } Output;
struct LedgerArchiveReader {
    void *library, *stream;
    FILE *file;
    size_t (*decode)(void *, Output *, Input *);
    size_t (*release)(void *);
    unsigned (*is_error)(size_t);
    unsigned char input[131072], output[131072], *line;
    size_t in_size, in_pos, out_size, out_pos, line_capacity, remaining;
    int eof, failed;
};
void ledger_archive_close(LedgerArchiveReader *r) {
    if (!r) return;
    if (r->stream && r->release) r->release(r->stream);
    if (r->file) fclose(r->file);
    if (r->library) dlclose(r->library);
    free(r->line); free(r);
}
LedgerArchiveReader *ledger_archive_open(const char *path, const char *library) {
    LedgerArchiveReader *r = calloc(1, sizeof(*r));
    if (!r) return NULL;
    r->library = dlopen(library, RTLD_NOW | RTLD_LOCAL);
    if (!r->library) { ledger_archive_close(r); return NULL; }
    void *(*create)(void) = dlsym(r->library, "ZSTD_createDStream");
    size_t (*initialize)(void *) = dlsym(r->library, "ZSTD_initDStream");
    r->decode = dlsym(r->library, "ZSTD_decompressStream");
    r->release = dlsym(r->library, "ZSTD_freeDStream");
    r->is_error = dlsym(r->library, "ZSTD_isError");
    if (!create || !initialize || !r->decode || !r->release || !r->is_error ||
        !(r->stream = create()) || r->is_error(initialize(r->stream)) || !(r->file = fopen(path, "rb"))) {
        ledger_archive_close(r); return NULL;
    }
    r->remaining = 1;
    return r;
}
LedgerArchiveReader *ledger_plain_open(const char *path) {
    LedgerArchiveReader *r = calloc(1, sizeof(*r));
    if (!r) return NULL;
    r->file = fopen(path, "rb");
    if (!r->file) { free(r); return NULL; }
    return r;
}
ssize_t ledger_archive_next(LedgerArchiveReader *r, const unsigned char **line) {
    if (r->failed) return -1;
    if (!r->stream) {
        ssize_t count = getline((char **)&r->line, &r->line_capacity, r->file);
        if (count < 0) return feof(r->file) ? 0 : -1;
        *line = r->line; return count;
    }
    size_t count = 0;
    for (;;) {
        if (r->out_pos < r->out_size) {
            unsigned char *start = r->output + r->out_pos;
            unsigned char *end = memchr(start, '\n', r->out_size - r->out_pos);
            size_t length = end ? (size_t)(end - start + 1) : r->out_size - r->out_pos;
            if (count + length > 128 * 1024 * 1024) { r->failed = 1; return -1; }
            if (count + length > r->line_capacity) {
                size_t capacity = (count + length) * 2;
                void *next = realloc(r->line, capacity);
                if (!next) { r->failed = 1; return -1; }
                r->line = next; r->line_capacity = capacity;
            }
            memcpy(r->line + count, start, length); count += length; r->out_pos += length;
            if (end) { *line = r->line; return (ssize_t)count; }
        }
        if (r->in_pos == r->in_size && !r->eof) {
            r->in_size = fread(r->input, 1, sizeof(r->input), r->file); r->in_pos = 0;
            if (!r->in_size) { if (ferror(r->file)) { r->failed = 1; return -1; } r->eof = 1; }
        }
        if (r->eof && r->in_pos == r->in_size && r->remaining == 0) {
            *line = r->line; return (ssize_t)count;
        }
        Input in = { r->input, r->in_size, r->in_pos };
        Output out = { r->output, sizeof(r->output), 0 };
        r->remaining = r->decode(r->stream, &out, &in);
        if (r->is_error(r->remaining)) { r->failed = 1; return -1; }
        if (r->eof && !out.pos && r->remaining != 0) { r->failed = 1; return -1; }
        r->in_pos = in.pos; r->out_pos = 0; r->out_size = out.pos;
    }
}
