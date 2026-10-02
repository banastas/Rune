/* A growable text buffer. Generated for the fidelity harness. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "buffer.h"

#define INITIAL_CAPACITY 64
#define MAX(a, b) ((a) > (b) ? (a) : (b))

typedef struct {
    char *data;
    size_t length;
    size_t capacity;
} Buffer;

static const char *const EMPTY = "";
static unsigned long allocations = 0;

enum Status { BUFFER_OK = 0, BUFFER_NOMEM = -1 };

/* Makes room for at least `extra` more bytes. */
static int buffer_reserve(Buffer *buffer, size_t extra) {
    if (buffer->length + extra <= buffer->capacity) {
        return BUFFER_OK;
    }
    size_t capacity = MAX(buffer->capacity * 2, buffer->length + extra);
    char *data = realloc(buffer->data, capacity);
    if (data == NULL) {
        return BUFFER_NOMEM;
    }
    buffer->data = data;
    buffer->capacity = capacity;
    allocations++;
    return BUFFER_OK;
}

int buffer_append(Buffer *buffer, const char *text) {
    size_t length = strlen(text);
    int status = buffer_reserve(buffer, length + 1);
    if (status != BUFFER_OK) {
        return status;
    }
    memcpy(buffer->data + buffer->length, text, length);
    buffer->length += length;
    buffer->data[buffer->length] = '\0';
    return BUFFER_OK;
}

int main(int argc, char **argv) {
    Buffer buffer = { .data = NULL, .length = 0, .capacity = 0 };
    for (int i = 1; i < argc; i++) {
        buffer_append(&buffer, argv[i]);
        buffer_append(&buffer, i + 1 < argc ? " " : "\n");
    }
    printf("%zu bytes, %lu allocations: %s", buffer.length, allocations, buffer.data ? buffer.data : EMPTY);
    free(buffer.data);
    return 0;
}
