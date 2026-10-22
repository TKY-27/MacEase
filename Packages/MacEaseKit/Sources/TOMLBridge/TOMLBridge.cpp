#include "TOMLBridge.h"

// Unmodified upstream uses deprecated literal operator spacing.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-literal-operator"
#include "toml.hpp"
#pragma clang diagnostic pop

#include <cstdlib>
#include <cstring>
#include <new>
#include <sstream>
#include <string>
#include <string_view>
#include <utility>

struct MCTomlDocument {
    toml::table table;
};

struct MCTomlCursor {
    toml::table::iterator position;
    toml::table::iterator end;
};

static toml::node *native(MCTomlNode *node) noexcept {
    return reinterpret_cast<toml::node *>(node);
}

static const toml::node *native(const MCTomlNode *node) noexcept {
    return reinterpret_cast<const toml::node *>(node);
}

static MCTomlNode *opaque(toml::node *node) noexcept {
    return reinterpret_cast<MCTomlNode *>(node);
}

static MCTomlOwnedBytes copied(std::string_view source) noexcept {
    auto *bytes = static_cast<char *>(std::malloc(source.size() + 1));
    if (!bytes) return {nullptr, 0};
    std::memcpy(bytes, source.data(), source.size());
    bytes[source.size()] = '\0';
    return {bytes, source.size()};
}

extern "C" MCTomlDocument *mc_toml_parse(const char *bytes, size_t length, MCTomlParseError *error) {
    if (error) *error = {};
    try {
        return new MCTomlDocument{toml::parse(std::string_view{bytes, length})};
    } catch (const toml::parse_error &failure) {
        if (error) {
            error->line = failure.source().begin.line;
            error->message = copied(failure.description());
        }
    } catch (const std::exception &failure) {
        if (error) error->message = copied(failure.what());
    } catch (...) {
        if (error) error->message = copied("Unknown TOML parsing failure");
    }
    return nullptr;
}

extern "C" MCTomlDocument *mc_toml_create(void) {
    try {
        return new MCTomlDocument{};
    } catch (...) {
        return nullptr;
    }
}

extern "C" void mc_toml_destroy(MCTomlDocument *document) {
    delete document;
}

extern "C" MCTomlNode *mc_toml_root(MCTomlDocument *document) {
    return document ? opaque(&document->table) : nullptr;
}

extern "C" int mc_toml_kind(const MCTomlNode *node) {
    if (!node) return 0;
    const auto *value = native(node);
    if (value->is_table()) return MCTomlTable;
    if (value->is_array()) return MCTomlArray;
    if (value->is_string()) return MCTomlStringValue;
    if (value->is_integer()) return MCTomlInteger;
    if (value->is_floating_point()) return MCTomlFloat;
    if (value->is_boolean()) return MCTomlBool;
    if (value->is_date()) return MCTomlDate;
    if (value->is_time()) return MCTomlTime;
    if (value->is_date_time()) return MCTomlDateTime;
    return 0;
}

extern "C" size_t mc_toml_count(const MCTomlNode *node) {
    if (!node) return 0;
    if (const auto *table = native(node)->as_table()) return table->size();
    if (const auto *array = native(node)->as_array()) return array->size();
    return 0;
}

extern "C" MCTomlNode *mc_toml_array_child(MCTomlNode *node, size_t index) {
    if (!node) return nullptr;
    if (auto *array = native(node)->as_array()) return opaque(array->get(index));
    return nullptr;
}

extern "C" MCTomlCursor *mc_toml_cursor_create(MCTomlNode *node) {
    if (!node) return nullptr;
    auto *table = native(node)->as_table();
    if (!table) return nullptr;
    try {
        return new MCTomlCursor{table->begin(), table->end()};
    } catch (...) {
        return nullptr;
    }
}

extern "C" bool mc_toml_cursor_next(MCTomlCursor *cursor, MCTomlString *key, MCTomlNode **child) {
    if (!cursor || !key || !child || cursor->position == cursor->end) return false;
    const auto bytes = cursor->position->first.str();
    *key = {bytes.data(), bytes.size()};
    *child = opaque(&cursor->position->second);
    ++cursor->position;
    return true;
}

extern "C" void mc_toml_cursor_destroy(MCTomlCursor *cursor) {
    delete cursor;
}

extern "C" MCTomlString mc_toml_string(const MCTomlNode *node) {
    if (!node) return {};
    const auto *value = native(node)->as_string();
    if (!value) return {};
    const auto &string = value->get();
    return {string.data(), string.size()};
}

extern "C" int64_t mc_toml_integer(const MCTomlNode *node) {
    return native(node)->as_integer()->get();
}

extern "C" double mc_toml_float(const MCTomlNode *node) {
    return native(node)->as_floating_point()->get();
}

extern "C" bool mc_toml_bool(const MCTomlNode *node) {
    return native(node)->as_boolean()->get();
}

extern "C" MCTomlCalendar mc_toml_calendar(const MCTomlNode *node) {
    MCTomlCalendar result{};
    const auto *value = native(node);
    if (const auto *dateTime = value->as_date_time()) {
        const auto &calendar = dateTime->get();
        result.year = calendar.date.year;
        result.month = calendar.date.month;
        result.day = calendar.date.day;
        result.hour = calendar.time.hour;
        result.minute = calendar.time.minute;
        result.second = calendar.time.second;
        result.nanosecond = calendar.time.nanosecond;
        result.hasOffset = calendar.offset.has_value();
        if (result.hasOffset) result.offsetMinutes = calendar.offset->minutes;
    } else if (const auto *date = value->as_date()) {
        result.year = date->get().year;
        result.month = date->get().month;
        result.day = date->get().day;
    } else if (const auto *time = value->as_time()) {
        result.hour = time->get().hour;
        result.minute = time->get().minute;
        result.second = time->get().second;
        result.nanosecond = time->get().nanosecond;
    }
    return result;
}

static bool insert(toml::node *parent, std::string_view key, MCTomlInput input, toml::node **child) {
    auto *table = parent->as_table();
    auto *array = parent->as_array();
    if (!table && !array) return false;
    const std::string string{input.bytes ? std::string_view{input.bytes, input.length} : std::string_view{}};
    auto append = [&](auto &&value) {
        if (table) {
            const auto result = table->insert(key, std::forward<decltype(value)>(value));
            if (!result.second) return false;
            *child = &result.first->second;
        } else {
            array->push_back(std::forward<decltype(value)>(value));
            *child = array->get(array->size() - 1);
        }
        return true;
    };
    switch (input.kind) {
    case MCTomlTable: return append(toml::table{});
    case MCTomlArray: return append(toml::array{});
    case MCTomlStringValue: return append(string);
    case MCTomlInteger: return append(input.integer);
    case MCTomlFloat: return append(input.real);
    case MCTomlBool: return append(input.flag);
    default: return false;
    }
}

extern "C" bool mc_toml_insert(MCTomlNode *parent, const char *key, size_t keyLength,
                                 MCTomlInput input, MCTomlNode **child) {
    if (!parent || !child || (!key && keyLength)) return false;
    *child = nullptr;
    try {
        toml::node *inserted = nullptr;
        const bool success = insert(native(parent), std::string_view{key ? key : "", keyLength}, input, &inserted);
        *child = opaque(inserted);
        return success;
    } catch (...) {
        return false;
    }
}

extern "C" bool mc_toml_render(const MCTomlDocument *document, MCTomlOwnedBytes *output) {
    if (!document || !output) return false;
    *output = {};
    try {
        const auto flags = toml::format_flags::allow_literal_strings
            | toml::format_flags::allow_multi_line_strings
            | toml::format_flags::allow_unicode_strings
            | toml::format_flags::relaxed_float_precision;
        std::ostringstream stream;
        stream << toml::toml_formatter{document->table, flags};
        const auto rendered = stream.str();
        *output = copied(rendered);
        return output->bytes != nullptr;
    } catch (...) {
        return false;
    }
}

extern "C" void mc_toml_free_bytes(MCTomlOwnedBytes bytes) {
    std::free(bytes.bytes);
}
