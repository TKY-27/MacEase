#ifndef MACEASE_TOML_BRIDGE_H
#define MACEASE_TOML_BRIDGE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct MCTomlDocument MCTomlDocument;
typedef struct MCTomlNode MCTomlNode;
typedef struct MCTomlCursor MCTomlCursor;

typedef struct {
    const char *bytes;
    size_t length;
} MCTomlString;

typedef struct {
    char *bytes;
    size_t length;
} MCTomlOwnedBytes;

typedef struct {
    MCTomlOwnedBytes message;
    uint32_t line;
} MCTomlParseError;

enum {
    MCTomlTable = 1,
    MCTomlArray,
    MCTomlStringValue,
    MCTomlInteger,
    MCTomlFloat,
    MCTomlBool,
    MCTomlDate,
    MCTomlTime,
    MCTomlDateTime
};

typedef struct {
    int kind;
    const char *bytes;
    size_t length;
    int64_t integer;
    double real;
    bool flag;
} MCTomlInput;

typedef struct {
    int32_t year;
    uint8_t month;
    uint8_t day;
    uint8_t hour;
    uint8_t minute;
    uint8_t second;
    uint32_t nanosecond;
    bool hasOffset;
    int16_t offsetMinutes;
} MCTomlCalendar;

MCTomlDocument *mc_toml_parse(const char *bytes, size_t length, MCTomlParseError *error);
MCTomlDocument *mc_toml_create(void);
void mc_toml_destroy(MCTomlDocument *document);
MCTomlNode *mc_toml_root(MCTomlDocument *document);
int mc_toml_kind(const MCTomlNode *node);
size_t mc_toml_count(const MCTomlNode *node);
MCTomlNode *mc_toml_array_child(MCTomlNode *node, size_t index);
MCTomlCursor *mc_toml_cursor_create(MCTomlNode *node);
bool mc_toml_cursor_next(MCTomlCursor *cursor, MCTomlString *key, MCTomlNode **child);
void mc_toml_cursor_destroy(MCTomlCursor *cursor);
MCTomlString mc_toml_string(const MCTomlNode *node);
int64_t mc_toml_integer(const MCTomlNode *node);
double mc_toml_float(const MCTomlNode *node);
bool mc_toml_bool(const MCTomlNode *node);
MCTomlCalendar mc_toml_calendar(const MCTomlNode *node);
bool mc_toml_insert(MCTomlNode *parent, const char *key, size_t keyLength,
                    MCTomlInput input, MCTomlNode **child);
bool mc_toml_render(const MCTomlDocument *document, MCTomlOwnedBytes *output);
void mc_toml_free_bytes(MCTomlOwnedBytes bytes);

#ifdef __cplusplus
}
#endif

#endif
