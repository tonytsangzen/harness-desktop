#include "json.h"

#include <cmath>
#include <cstdio>
#include <cstring>
#include <limits>

namespace dsh {
namespace Json {

// ---- Value ----

Value Value::MakeBool(bool b) {
    Value v;
    v.type_ = Type::Bool;
    v.bool_ = b;
    return v;
}

Value Value::MakeNumber(double n) {
    Value v;
    v.type_ = Type::Number;
    v.num_ = n;
    return v;
}

Value Value::MakeString(std::string s) {
    Value v;
    v.type_ = Type::String;
    v.str_ = std::move(s);
    return v;
}

Value Value::MakeArray() {
    Value v;
    v.type_ = Type::Array;
    return v;
}

Value Value::MakeObject() {
    Value v;
    v.type_ = Type::Object;
    return v;
}

const Value* Value::Get(const std::string& key) const {
    if (type_ != Type::Object) return nullptr;
    for (const auto& m : obj_) {
        if (m.first == key) return &m.second;
    }
    return nullptr;
}

std::vector<std::string> Value::Keys() const {
    std::vector<std::string> keys;
    if (type_ != Type::Object) return keys;
    keys.reserve(obj_.size());
    for (const auto& m : obj_) keys.push_back(m.first);
    return keys;
}

Value& Value::GetOrCreate(const std::string& key) {
    if (type_ != Type::Object) {
        *this = MakeObject();
    }
    for (auto& m : obj_) {
        if (m.first == key) return m.second;
    }
    obj_.emplace_back(key, Value());
    return obj_.back().second;
}

void Value::Push(Value v) {
    if (type_ != Type::Array) {
        *this = MakeArray();
    }
    arr_.push_back(std::move(v));
}

void Value::RemoveString(const std::string& s) {
    if (type_ != Type::Array) return;
    for (auto it = arr_.begin(); it != arr_.end(); ++it) {
        if (it->IsString() && it->str_ == s) {
            arr_.erase(it);
            return;
        }
    }
}

void Value::Set(const std::string& key, Value v) {
    if (type_ != Type::Object) {
        *this = MakeObject();
    }
    for (auto& m : obj_) {
        if (m.first == key) {
            m.second = std::move(v);
            return;
        }
    }
    obj_.emplace_back(key, std::move(v));
}

// ---- Parser ----

namespace {

struct Parser {
    const std::string& s;
    size_t i = 0;
    bool error = false;

    explicit Parser(const std::string& text) : s(text) {}

    void SkipWs() {
        while (i < s.size() && (s[i] == ' ' || s[i] == '\t' || s[i] == '\n' || s[i] == '\r')) ++i;
    }

    bool ParseValue(Value* out) {
        SkipWs();
        if (i >= s.size()) return Fail();
        switch (s[i]) {
            case '{': return ParseObject(out);
            case '[': return ParseArray(out);
            case '"': return ParseStringValue(out);
            case 't': case 'f': case 'n': return ParseLiteral(out);
            default: return ParseNumber(out);
        }
    }

    bool Fail() {
        error = true;
        return false;
    }

    bool ParseObject(Value* out) {
        ++i; // '{'
        Value obj = Value::MakeObject();
        SkipWs();
        if (i < s.size() && s[i] == '}') { ++i; *out = std::move(obj); return true; }
        while (i < s.size()) {
            SkipWs();
            std::string key;
            if (!ParseString(&key)) return Fail();
            SkipWs();
            if (i >= s.size() || s[i] != ':') return Fail();
            ++i;
            Value v;
            if (!ParseValue(&v)) return Fail();
            obj.Set(key, std::move(v));
            SkipWs();
            if (i >= s.size()) return Fail();
            if (s[i] == ',') { ++i; continue; }
            if (s[i] == '}') { ++i; *out = std::move(obj); return true; }
            return Fail();
        }
        return Fail();
    }

    bool ParseArray(Value* out) {
        ++i; // '['
        Value arr = Value::MakeArray();
        SkipWs();
        if (i < s.size() && s[i] == ']') { ++i; *out = std::move(arr); return true; }
        while (i < s.size()) {
            Value v;
            if (!ParseValue(&v)) return Fail();
            arr.Push(std::move(v));
            SkipWs();
            if (i >= s.size()) return Fail();
            if (s[i] == ',') { ++i; continue; }
            if (s[i] == ']') { ++i; *out = std::move(arr); return true; }
            return Fail();
        }
        return Fail();
    }

    // Parses a quoted string into *out (without the surrounding quotes).
    bool ParseString(std::string* out) {
        SkipWs();
        if (i >= s.size() || s[i] != '"') return false;
        ++i;
        std::string result;
        while (i < s.size()) {
            char c = s[i++];
            if (c == '"') {
                *out = std::move(result);
                return true;
            }
            if (c == '\\') {
                if (i >= s.size()) return false;
                char e = s[i++];
                switch (e) {
                    case '"': result += '"'; break;
                    case '\\': result += '\\'; break;
                    case '/': result += '/'; break;
                    case 'b': result += '\b'; break;
                    case 'f': result += '\f'; break;
                    case 'n': result += '\n'; break;
                    case 'r': result += '\r'; break;
                    case 't': result += '\t'; break;
                    case 'u': {
                        // \uXXXX — surrogate pairs are kept as UTF-8 code
                        // points; lone surrogates fall back to U+FFFD.
                        if (i + 4 > s.size()) return false;
                        unsigned cp = 0;
                        for (int k = 0; k < 4; ++k) {
                            char h = s[i + k];
                            cp <<= 4;
                            if (h >= '0' && h <= '9') cp |= static_cast<unsigned>(h - '0');
                            else if (h >= 'a' && h <= 'f') cp |= static_cast<unsigned>(h - 'a' + 10);
                            else if (h >= 'A' && h <= 'F') cp |= static_cast<unsigned>(h - 'A' + 10);
                            else return false;
                        }
                        i += 4;
                        if (cp >= 0xD800 && cp <= 0xDBFF && i + 6 <= s.size() &&
                            s[i] == '\\' && s[i + 1] == 'u') {
                            unsigned lo = 0;
                            bool ok = true;
                            for (int k = 0; k < 4; ++k) {
                                char h = s[i + 2 + k];
                                lo <<= 4;
                                if (h >= '0' && h <= '9') lo |= static_cast<unsigned>(h - '0');
                                else if (h >= 'a' && h <= 'f') lo |= static_cast<unsigned>(h - 'a' + 10);
                                else if (h >= 'A' && h <= 'F') lo |= static_cast<unsigned>(h - 'A' + 10);
                                else { ok = false; break; }
                            }
                            if (ok && lo >= 0xDC00 && lo <= 0xDFFF) {
                                cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                                i += 6;
                            }
                        }
                        // Encode as UTF-8.
                        if (cp < 0x80) {
                            result += static_cast<char>(cp);
                        } else if (cp < 0x800) {
                            result += static_cast<char>(0xC0 | (cp >> 6));
                            result += static_cast<char>(0x80 | (cp & 0x3F));
                        } else if (cp < 0x10000) {
                            result += static_cast<char>(0xE0 | (cp >> 12));
                            result += static_cast<char>(0x80 | ((cp >> 6) & 0x3F));
                            result += static_cast<char>(0x80 | (cp & 0x3F));
                        } else {
                            result += static_cast<char>(0xF0 | (cp >> 18));
                            result += static_cast<char>(0x80 | ((cp >> 12) & 0x3F));
                            result += static_cast<char>(0x80 | ((cp >> 6) & 0x3F));
                            result += static_cast<char>(0x80 | (cp & 0x3F));
                        }
                        break;
                    }
                    default: return false;
                }
            } else {
                result += c;
            }
        }
        return false;
    }

    bool ParseStringValue(Value* out) {
        std::string s;
        if (!ParseString(&s)) return false;
        *out = Value::MakeString(std::move(s));
        return true;
    }

    bool ParseLiteral(Value* out) {
        if (s.compare(i, 4, "true") == 0) {
            i += 4;
            *out = Value::MakeBool(true);
            return true;
        }
        if (s.compare(i, 5, "false") == 0) {
            i += 5;
            *out = Value::MakeBool(false);
            return true;
        }
        if (s.compare(i, 4, "null") == 0) {
            i += 4;
            *out = Value();
            return true;
        }
        return false;
    }

    bool ParseNumber(Value* out) {
        size_t start = i;
        if (i < s.size() && s[i] == '-') ++i;
        while (i < s.size() && s[i] >= '0' && s[i] <= '9') ++i;
        if (i < s.size() && s[i] == '.') {
            ++i;
            while (i < s.size() && s[i] >= '0' && s[i] <= '9') ++i;
        }
        if (i < s.size() && (s[i] == 'e' || s[i] == 'E')) {
            ++i;
            if (i < s.size() && (s[i] == '+' || s[i] == '-')) ++i;
            while (i < s.size() && s[i] >= '0' && s[i] <= '9') ++i;
        }
        if (i == start) return false;
        *out = Value::MakeNumber(strtod(s.substr(start, i - start).c_str(), nullptr));
        return true;
    }
};

} // namespace

bool Parse(const std::string& text, Value* out) {
    Parser p(text);
    Value v;
    if (!p.ParseValue(&v) || p.error) return false;
    p.SkipWs();
    if (p.i != text.size()) return false; // trailing garbage
    *out = std::move(v);
    return true;
}

// ---- Serializer ----

namespace {

void AppendString(std::string* out, const std::string& s) {
    out->push_back('"');
    for (char c : s) {
        switch (c) {
            case '"': *out += "\\\""; break;
            case '\\': *out += "\\\\"; break;
            case '\b': *out += "\\b"; break;
            case '\f': *out += "\\f"; break;
            case '\n': *out += "\\n"; break;
            case '\r': *out += "\\r"; break;
            case '\t': *out += "\\t"; break;
            default:
                if (static_cast<unsigned char>(c) < 0x20) {
                    char buf[8];
                    std::snprintf(buf, sizeof(buf), "\\u%04x", c);
                    *out += buf;
                } else {
                    out->push_back(c);
                }
        }
    }
    out->push_back('"');
}

void AppendValue(std::string* out, const Value& v, bool pretty, int depth) {
    auto indent = [&](int d) { if (pretty) out->append(static_cast<size_t>(d) * 2, ' '); };
    switch (v.type()) {
        case Value::Type::Null: *out += "null"; break;
        case Value::Type::Bool: *out += v.AsBool() ? "true" : "false"; break;
        case Value::Type::Number: {
            double n = v.AsNumber();
            if (std::isfinite(n) && n == std::floor(n) &&
                std::fabs(n) < 9.0e15) {
                char buf[32];
                std::snprintf(buf, sizeof(buf), "%.0f", n);
                *out += buf;
            } else {
                char buf[32];
                std::snprintf(buf, sizeof(buf), "%g", n);
                *out += buf;
            }
            break;
        }
        case Value::Type::String: AppendString(out, v.AsString()); break;
        case Value::Type::Array: {
            if (v.Size() == 0) { *out += "[]"; break; }
            *out += "[";
            if (pretty) *out += "\n";
            for (size_t i = 0; i < v.Size(); ++i) {
                if (i) *out += pretty ? ",\n" : ",";
                indent(depth + 1);
                AppendValue(out, v.At(i), pretty, depth + 1);
            }
            if (pretty) *out += "\n";
            indent(depth);
            *out += "]";
            break;
        }
        case Value::Type::Object: {
            auto keys = v.Keys();
            if (keys.empty()) { *out += "{}"; break; }
            *out += "{";
            if (pretty) *out += "\n";
            for (size_t i = 0; i < keys.size(); ++i) {
                if (i) *out += pretty ? ",\n" : ",";
                indent(depth + 1);
                AppendString(out, keys[i]);
                *out += pretty ? ": " : ":";
                AppendValue(out, *v.Get(keys[i]), pretty, depth + 1);
            }
            if (pretty) *out += "\n";
            indent(depth);
            *out += "}";
            break;
        }
    }
}

} // namespace

std::string Stringify(const Value& v, bool pretty) {
    std::string out;
    AppendValue(&out, v, pretty, 0);
    return out;
}

} // namespace Json
} // namespace dsh
