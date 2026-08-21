#pragma once

#include <string>
#include <vector>

namespace dsh {

// Minimal JSON helpers tailored to npm/node metadata payloads.
// Extracts the value of a top-level `"key"` string property.
bool JsonGetString(const std::string& json, const std::string& key, std::string& out);

// From nodejs.org/dist/index.json: returns the `version` of the first entry
// whose `lts` is a non-empty string (i.e. the newest LTS). Returns false if
// none is found.
bool JsonFirstLTSVersion(const std::string& json, std::string& out);

// ---- Lightweight structural helpers (plugin market / profile package.json) ----

// Range [start,end) of the `key` value (object, array or string) found at the
// top level. `start`/`end` are byte offsets into `json`. Returns false when
// the key is missing or its value is a scalar.
bool JsonGetValueRange(const std::string& json, const std::string& key,
                       size_t& start, size_t& end);

// Same as JsonGetValueRange but searches only within [scopeStart,scopeEnd)
// (e.g. a nested object found earlier). The returned range is still an offset
// into `json`.
bool JsonGetValueRangeAt(const std::string& json, size_t scopeStart, size_t scopeEnd,
                         const std::string& key, size_t& start, size_t& end);

// String value of `key` inside the object range [start,end).
bool JsonObjectGetString(const std::string& json, size_t start, size_t end,
                         const std::string& key, std::string& out);

// All property keys of the object at [start,end), in document order.
void JsonObjectKeys(const std::string& json, size_t start, size_t end,
                    std::vector<std::string>& out);

// String-array value of `key` inside [start,end).
bool JsonObjectGetStringArray(const std::string& json, size_t start, size_t end,
                              const std::string& key, std::vector<std::string>& out);

// Iterates the objects of an array range: `pos` starts at the array start;
// each call returns true and fills objStart/objEnd (the object's `{..}` span),
// advancing `pos` past the object. Returns false when exhausted.
bool JsonArrayNextObject(const std::string& json, size_t& pos,
                         size_t& objStart, size_t& objEnd);

// Replaces the string-array value of `key` inside [scopeStart,scopeEnd) with
// `newItems`, writing the full modified document to `out`. Returns false when
// the key is missing or not a string array (callers treat that as an error).
bool JsonReplaceStringArray(const std::string& json, size_t scopeStart, size_t scopeEnd,
                            const std::string& key, const std::vector<std::string>& newItems,
                            std::string& out);

} // namespace dsh
