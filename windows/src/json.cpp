#include "json.h"

namespace dsh {

namespace {

// Skips whitespace.
size_t SkipWs(const std::string& s, size_t i) {
    while (i < s.size() && (s[i] == ' ' || s[i] == '\t' || s[i] == '\n' || s[i] == '\r')) i++;
    return i;
}

// Parses a JSON string literal at s[i] (s[i] == '"'), returning the decoded
// value in `out` and advancing `i` past the closing quote.
bool ParseString(const std::string& s, size_t& i, std::string& out) {
    if (i >= s.size() || s[i] != '"') return false;
    i++;
    out.clear();
    while (i < s.size()) {
        char c = s[i];
        if (c == '\\') {
            i++;
            if (i >= s.size()) return false;
            switch (s[i]) {
                case '"': out += '"'; break;
                case '\\': out += '\\'; break;
                case '/': out += '/'; break;
                case 'b': out += '\b'; break;
                case 'f': out += '\f'; break;
                case 'n': out += '\n'; break;
                case 'r': out += '\r'; break;
                case 't': out += '\t'; break;
                case 'u': {
                    if (i + 4 >= s.size()) return false;
                    // Best-effort: convert a BMP code unit to UTF-8.
                    unsigned code = 0;
                    for (int k = 1; k <= 4; k++) {
                        char h = s[i + k];
                        code <<= 4;
                        if (h >= '0' && h <= '9') code |= (h - '0');
                        else if (h >= 'a' && h <= 'f') code |= (h - 'a' + 10);
                        else if (h >= 'A' && h <= 'F') code |= (h - 'A' + 10);
                        else return false;
                    }
                    i += 4;
                    if (code < 0x80) out += static_cast<char>(code);
                    else if (code < 0x800) {
                        out += static_cast<char>(0xC0 | (code >> 6));
                        out += static_cast<char>(0x80 | (code & 0x3F));
                    } else {
                        out += static_cast<char>(0xE0 | (code >> 12));
                        out += static_cast<char>(0x80 | ((code >> 6) & 0x3F));
                        out += static_cast<char>(0x80 | (code & 0x3F));
                    }
                    break;
                }
                default: return false;
            }
            i++;
        } else if (c == '"') {
            i++;
            return true;
        } else {
            out += c;
            i++;
        }
    }
    return false;
}

// From position i, find the property `key` and parse its string value.
// Handles one level of object nesting (sufficient for npm/node metadata).
bool ObjectGetString(const std::string& s, size_t start, size_t end, const std::string& key, std::string& out) {
    size_t i = start;
    while (i < end) {
        i = SkipWs(s, i);
        if (i >= end || s[i] != '"') { i++; continue; }
        std::string propKey;
        if (!ParseString(s, i, propKey)) { i++; continue; }
        i = SkipWs(s, i);
        if (i < end && s[i] == ':') {
            i = SkipWs(s, i + 1);
            if (propKey == key) {
                if (i < end && s[i] == '"') {
                    ParseString(s, i, out);
                    return true;
                }
                return false; // key present but not a string
            }
            // Skip the value (string or anything else).
            if (i < end && s[i] == '"') { std::string discard; ParseString(s, i, discard); }
            else {
                int depth = 0;
                while (i < end && !(s[i] == ',' || s[i] == '}') && !(s[i] == '}' && depth == 0)) {
                    if (s[i] == '{' || s[i] == '[') depth++;
                    else if (s[i] == '}' || s[i] == ']') { if (depth > 0) depth--; else break; }
                    i++;
                }
            }
        } else {
            i++;
        }
    }
    return false;
}

} // namespace

bool JsonGetString(const std::string& json, const std::string& key, std::string& out) {
    return ObjectGetString(json, 0, json.size(), key, out);
}

bool JsonFirstLTSVersion(const std::string& json, std::string& out) {
    // Walk top-level array entries: { ... "version":"vX", ... "lts":"..." }.
    size_t i = SkipWs(json, 0);
    if (i >= json.size() || json[i] != '[') return false;
    i++;
    while (i < json.size()) {
        i = SkipWs(json, i);
        if (i >= json.size()) break;
        if (json[i] == ']') return false;
        if (json[i] == '{') {
            // Find the object end.
            size_t objStart = i;
            int depth = 0;
            while (i < json.size()) {
                if (json[i] == '{') depth++;
                else if (json[i] == '}') {
                    depth--;
                    if (depth == 0) break;
                }
                i++;
            }
            if (i >= json.size()) return false;
            size_t objEnd = i + 1; // past '}'

            std::string lts;
            if (ObjectGetString(json, objStart, objEnd, "lts", lts) && !lts.empty()) {
                std::string version;
                if (ObjectGetString(json, objStart, objEnd, "version", version)) {
                    out = version;
                    return true;
                }
                return false;
            }
            i = objEnd;
        } else {
            i++;
        }
    }
    return false;
}

// ---- Lightweight structural helpers (plugin market / profile package.json) ----

namespace {

// Finds the value span of `key` inside [start,end): sets valStart/valEnd to
// the value's byte range (for object/array/string values). Handles nested
// braces/brackets by depth counting. Returns false when missing.
bool FindValueRange(const std::string& s, size_t start, size_t end,
                    const std::string& key, size_t& valStart, size_t& valEnd) {
    size_t i = start;
    while (i < end) {
        i = SkipWs(s, i);
        if (i >= end || s[i] != '"') { i++; continue; }
        std::string propKey;
        if (!ParseString(s, i, propKey)) { i++; continue; }
        i = SkipWs(s, i);
        if (i < end && s[i] == ':') {
            i = SkipWs(s, i + 1);
            if (propKey == key) {
                if (i >= end) return false;
                size_t vStart = i;
                size_t vEnd = 0;
                if (s[i] == '"') {
                    std::string discard;
                    if (!ParseString(s, i, discard)) return false;
                    vEnd = i;
                } else if (s[i] == '{' || s[i] == '[') {
                    int depth = 0;
                    while (i < end) {
                        if (s[i] == '{' || s[i] == '[') depth++;
                        else if (s[i] == '}' || s[i] == ']') {
                            depth--;
                            if (depth == 0) { i++; break; }
                        }
                        i++;
                    }
                    if (i > end) return false;
                    vEnd = i;
                } else {
                    return false; // scalar value
                }
                valStart = vStart;
                valEnd = vEnd;
                return true;
            }
            // Skip the value (string or anything else).
            if (i < end && s[i] == '"') { std::string discard; ParseString(s, i, discard); }
            else {
                int depth = 0;
                while (i < end) {
                    if (s[i] == '{' || s[i] == '[') depth++;
                    else if (s[i] == '}' || s[i] == ']') { if (depth > 0) depth--; else break; }
                    i++;
                }
            }
        } else {
            i++;
        }
    }
    return false;
}

// Skips a non-string JSON value starting at s[i], advancing i past it.
void SkipValue(const std::string& s, size_t& i, size_t end) {
    if (i < end && s[i] == '"') { std::string discard; ParseString(s, i, discard); return; }
    int depth = 0;
    while (i < end) {
        if (s[i] == '{' || s[i] == '[') depth++;
        else if (s[i] == '}' || s[i] == ']') { if (depth > 0) depth--; else break; }
        i++;
    }
}

std::string JsonEscapeString(const std::string& s) {
    std::string out;
    out += '"';
    for (char c : s) {
        switch (c) {
            case '"': out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\n': out += "\\n"; break;
            case '\r': out += "\\r"; break;
            case '\t': out += "\\t"; break;
            default: out += c;
        }
    }
    out += '"';
    return out;
}

} // namespace

bool JsonGetValueRange(const std::string& json, const std::string& key,
                       size_t& start, size_t& end) {
    return FindValueRange(json, 0, json.size(), key, start, end);
}

bool JsonGetValueRangeAt(const std::string& json, size_t scopeStart, size_t scopeEnd,
                         const std::string& key, size_t& start, size_t& end) {
    return FindValueRange(json, scopeStart, scopeEnd, key, start, end);
}

bool JsonObjectGetString(const std::string& json, size_t start, size_t end,
                         const std::string& key, std::string& out) {
    return ObjectGetString(json, start, end, key, out);
}

void JsonObjectKeys(const std::string& json, size_t start, size_t end,
                    std::vector<std::string>& out) {
    size_t i = start;
    while (i < end) {
        i = SkipWs(json, i);
        if (i >= end || json[i] != '"') { i++; continue; }
        std::string k;
        if (!ParseString(json, i, k)) { i++; continue; }
        out.push_back(k);
        i = SkipWs(json, i);
        if (i < end && json[i] == ':') {
            i = SkipWs(json, i + 1);
            SkipValue(json, i, end);
        }
    }
}

bool JsonObjectGetStringArray(const std::string& json, size_t start, size_t end,
                              const std::string& key, std::vector<std::string>& out) {
    size_t vs, ve;
    if (!FindValueRange(json, start, end, key, vs, ve)) return false;
    if (vs >= ve || json[vs] != '[') return false;
    size_t i = vs + 1;
    while (i < ve) {
        i = SkipWs(json, i);
        if (i >= ve || json[i] == ']') break;
        if (json[i] == '"') {
            std::string v;
            if (ParseString(json, i, v)) out.push_back(v);
            else i++;
        } else {
            SkipValue(json, i, ve);
        }
        i = SkipWs(json, i);
        if (i < ve && json[i] == ',') i++;
    }
    return true;
}

bool JsonArrayNextObject(const std::string& json, size_t& pos,
                         size_t& objStart, size_t& objEnd) {
    size_t i = pos;
    while (i < json.size()) {
        i = SkipWs(json, i);
        if (i >= json.size()) return false;
        if (json[i] == '{') {
            size_t start = i;
            int depth = 0;
            while (i < json.size()) {
                if (json[i] == '{' || json[i] == '[') depth++;
                else if (json[i] == '}' || json[i] == ']') {
                    depth--;
                    if (depth == 0) { i++; break; }
                }
                i++;
            }
            if (i > json.size()) return false;
            objStart = start;
            objEnd = i;
            pos = i;
            return true;
        }
        if (json[i] == ']' || json[i] == '}') return false;
        i++;
    }
    return false;
}

bool JsonReplaceStringArray(const std::string& json, size_t scopeStart, size_t scopeEnd,
                            const std::string& key, const std::vector<std::string>& newItems,
                            std::string& out) {
    size_t vs, ve;
    if (!FindValueRange(json, scopeStart, scopeEnd, key, vs, ve)) return false;
    if (vs >= ve || json[vs] != '[') return false;
    std::string arr = "[";
    for (size_t k = 0; k < newItems.size(); k++) {
        if (k) arr += ",";
        arr += JsonEscapeString(newItems[k]);
    }
    arr += "]";
    out = json.substr(0, vs) + arr + json.substr(ve);
    return true;
}

} // namespace dsh
