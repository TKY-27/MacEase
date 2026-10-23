#pragma once
#include "JSONCompare.h"
#include <algorithm>
#include <array>
#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <exception>
#include <fcntl.h>
#include <limits>
#include <memory>
#include <stdexcept>
#include <sys/stat.h>
#include <unistd.h>

class DiskFailure final : public std::exception {
  public:
    MEJSONCompareStatus status;
    int systemError;
    int icuError;
    const char *reason;
    DiskFailure(MEJSONCompareStatus s, const char *r, int e = 0, int u = 0)
        : status(s), systemError(e), icuError(u), reason(r) {}
    const char *what() const noexcept override {
        return reason;
    }
};
struct DiskOperation {
    int scratchDirectory;
    MEJSONCancelled cancelled;
    void *context;
    uint32_t untilPoll = 0;
    void poll() {
        if (cancelled && cancelled(context))
            throw DiskFailure(ME_JSON_COMPARE_CANCELLED, "cancelled");
    }
    void advance() {
        if (untilPoll == 0) {
            poll();
            untilPoll = 1024;
        }
        --untilPoll;
    }
};
inline thread_local DiskOperation *diskOperation = nullptr;
inline void diskPoll() {
    if (diskOperation)
        diskOperation->poll();
}
inline void diskAdvance() {
    if (diskOperation)
        diskOperation->advance();
}
inline off_t diskOffset(uint64_t index, uint64_t width, uint64_t extra = 0) {
    constexpr uint64_t limit = std::numeric_limits<off_t>::max();
    if (extra > limit || index > (limit - extra) / width)
        throw DiskFailure(ME_JSON_COMPARE_OFFSET_OVERFLOW, "file offset overflow");
    return static_cast<off_t>(index * width + extra);
}
template <class T> class DiskArray {
    static constexpr uint64_t capacity = 65536 / sizeof(T);
    mutable std::unique_ptr<std::array<T, capacity>> cache{new std::array<T, capacity>};
    mutable uint64_t base = 0;
    mutable int descriptor = -1;
    mutable bool dirty = false;
    mutable uint64_t diskLength = 0;
    uint64_t fileStart = 0;
    uint64_t size = 0;
    bool borrowed = false;
    void create() const {
        if (descriptor >= 0)
            return;
        diskPoll();
        if (!diskOperation)
            throw DiskFailure(ME_JSON_COMPARE_INTERNAL, "missing comparison context");
        char name[48];
        do {
            diskPoll();
            unsigned long long random;
            arc4random_buf(&random, sizeof(random));
            snprintf(name, sizeof(name), "macease-compare-%016llx", random);
            descriptor =
                openat(diskOperation->scratchDirectory, name, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
            if (descriptor < 0 && errno != EEXIST)
                throw DiskFailure(ME_JSON_COMPARE_IO, "create scratch", errno);
        } while (descriptor < 0);
        if (unlinkat(diskOperation->scratchDirectory, name, 0) != 0) {
            int failure = errno;
            close(descriptor);
            descriptor = -1;
            throw DiskFailure(ME_JSON_COMPARE_IO, "unlink scratch", failure);
        }
    }

    void flush() const {
        if (!dirty)
            return;
        create();
        uint64_t units = std::min(capacity, size - base);
        uint64_t bytes = units * sizeof(T), done = 0;
        while (done < bytes) {
            diskPoll();
            ssize_t n = pwrite(descriptor, reinterpret_cast<const char *>(cache->data()) + done, bytes - done,
                               diskOffset(base, sizeof(T), done));
            if (n < 0 && errno == EINTR)
                continue;
            if (n <= 0)
                throw DiskFailure(ME_JSON_COMPARE_IO, "write scratch", n < 0 ? errno : EIO);
            done += n;
        }
        diskLength = std::max(diskLength, base + units);
        dirty = false;
    }
    void readPage() const {
        uint64_t units = base < diskLength ? std::min(capacity, diskLength - base) : 0;
        uint64_t bytes = units * sizeof(T), done = 0;
        while (done < bytes) {
            diskPoll();
            ssize_t n = pread(descriptor, reinterpret_cast<char *>(cache->data()) + done, bytes - done,
                              diskOffset(base, sizeof(T), fileStart + done));
            if (n < 0 && errno == EINTR)
                continue;
            if (n <= 0)
                throw DiskFailure(ME_JSON_COMPARE_IO, "read span", n < 0 ? errno : EIO);
            done += n;
        }
    }
    void select(uint64_t index) const {
        uint64_t next = index / capacity * capacity;
        if (next == base)
            return;
        flush();
        base = next;
        readPage();
    }

  public:
    DiskArray() = default;
    DiskArray(int fd, uint64_t byteOffset, uint64_t count)
        : descriptor(fd), diskLength(count), fileStart(byteOffset), size(count), borrowed(true) {
        diskOffset(count, sizeof(T), byteOffset);
        readPage();
    }
    DiskArray(const DiskArray &) = delete;
    ~DiskArray() {
        if (descriptor >= 0 && !borrowed)
            close(descriptor);
    }
    uint64_t length() const {
        return size;
    }
    bool isEmpty() const {
        return size == 0;
    }
    T operator[](uint64_t index) const {
        diskAdvance();
        if (index >= size)
            throw DiskFailure(ME_JSON_COMPARE_INTERNAL, "scratch bounds");
        select(index);
        return (*cache)[index - base];
    }
    void set(uint64_t index, T value) {
        diskAdvance();
        if (borrowed)
            throw DiskFailure(ME_JSON_COMPARE_INTERNAL, "write borrowed span");
        if (index == UINT64_MAX)
            throw DiskFailure(ME_JSON_COMPARE_OFFSET_OVERFLOW, "cell index overflow");
        diskOffset(index + 1, sizeof(T));
        select(index);
        size = std::max(size, index + 1);
        (*cache)[index - base] = value;
        dirty = true;
    }
    void append(T value) {
        set(size, value);
    }
    void clear() {
        diskPoll();
        if (borrowed)
            throw DiskFailure(ME_JSON_COMPARE_INTERNAL, "clear borrowed span");
        size = 0;
        base = 0;
        diskLength = 0;
        dirty = false;
        if (descriptor >= 0 && ftruncate(descriptor, 0) != 0)
            throw DiskFailure(ME_JSON_COMPARE_IO, "truncate scratch", errno);
    }
    void swap(DiskArray &other) {
        cache.swap(other.cache);
        std::swap(base, other.base);
        std::swap(descriptor, other.descriptor);
        std::swap(dirty, other.dirty);
        std::swap(diskLength, other.diskLength);
        std::swap(size, other.size);
        std::swap(fileStart, other.fileStart);
        std::swap(borrowed, other.borrowed);
    }
};

class DiskUTF16 {
    DiskArray<char16_t> units;

  public:
    DiskUTF16() = default;
    explicit DiskUTF16(MEJSONUTF16Span span) : units(span.descriptor, span.byteOffset, span.byteLength / 2) {}
    uint64_t length() const {
        return units.length();
    }
    bool isEmpty() const {
        return units.isEmpty();
    }
    void remove() {
        units.clear();
    }
    char16_t operator[](uint64_t index) const {
        return units[index];
    }
    void append(int32_t scalar) {
        if (scalar <= 0xffff)
            units.append(scalar);
        else {
            units.append(0xd800 + ((scalar - 0x10000) >> 10));
            units.append(0xdc00 + ((scalar - 0x10000) & 1023));
        }
    }
    void setTo(int32_t scalar) {
        remove();
        append(scalar);
    }
    int32_t char32At(uint64_t index) const {
        int32_t c = units[index];
        if (c >= 0xdc00 && c <= 0xdfff && index > 0) {
            int32_t high = units[index - 1];
            if (high >= 0xd800 && high <= 0xdbff)
                return 0x10000 + ((high - 0xd800) << 10) + (c - 0xdc00);
        }
        if (c >= 0xd800 && c <= 0xdbff && index + 1 < length()) {
            int32_t low = units[index + 1];
            if (low >= 0xdc00 && low <= 0xdfff)
                return 0x10000 + ((c - 0xd800) << 10) + (low - 0xdc00);
        }
        return c;
    }
    uint64_t moveIndex32(uint64_t index, int64_t delta) const {
        while (delta > 0 && index < length()) {
            int32_t c = char32At(index);
            index += c > 0xffff ? 2 : 1;
            --delta;
        }
        while (delta < 0 && index > 0) {
            --index;
            char16_t c = units[index];
            if (c >= 0xdc00 && c <= 0xdfff && index > 0 && units[index - 1] >= 0xd800 &&
                units[index - 1] <= 0xdbff)
                --index;
            ++delta;
        }
        return index;
    }
    void replace(uint64_t start, uint64_t removed, const DiskUTF16 &replacement, uint64_t from,
                 uint64_t amount) {
        DiskArray<char16_t> next;
        for (uint64_t k = 0; k < start; k++)
            next.append(units[k]);
        for (uint64_t k = 0; k < amount; k++)
            next.append(replacement[from + k]);
        for (uint64_t k = start + removed; k < length(); k++)
            next.append(units[k]);
        units.swap(next);
    }
};
