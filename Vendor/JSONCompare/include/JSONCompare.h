#pragma once
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef enum {
    ME_JSON_COMPARE_OK,
    ME_JSON_COMPARE_CANCELLED,
    ME_JSON_COMPARE_IO,
    ME_JSON_COMPARE_INVALID_SPAN,
    ME_JSON_COMPARE_OFFSET_OVERFLOW,
    ME_JSON_COMPARE_ICU,
    ME_JSON_COMPARE_MEMORY,
    ME_JSON_COMPARE_INTERNAL
} MEJSONCompareStatus;
typedef struct {
    int descriptor;
    uint64_t byteOffset;
    uint64_t byteLength;
} MEJSONUTF16Span;
typedef int (*MEJSONCancelled)(void *context);
typedef struct {
    MEJSONCompareStatus status;
    int ordering;
    int systemError;
    int icuError;
} MEJSONCompareResult;
MEJSONCompareResult MEJSONCompareFoldedUTF16(MEJSONUTF16Span left, MEJSONUTF16Span right,
                                             int scratchDirectory, MEJSONCancelled cancelled, void *context);
#ifdef __cplusplus
}
#endif
