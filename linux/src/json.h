#pragma once

#include <string>
#include <vector>

namespace dsh {
namespace Json {

// Minimal JSON value tree (null / bool / number / string / array / object)
// with ordered object members — enough to parse the plugin market index and
// the dsh profile package.json, and to rewrite the latter. No external
// dependencies (the codebase otherwise hand-rolls its JSON snippets).
class Value {
public:
    enum class Type { Null, Bool, Number, String, Array, Object };

    Value() = default; // Null

    static Value MakeBool(bool b);
    static Value MakeNumber(double n);
    static Value MakeString(std::string s);
    static Value MakeArray();
    static Value MakeObject();

    Type type() const { return type_; }
    bool IsNull() const { return type_ == Type::Null; }
    bool IsBool() const { return type_ == Type::Bool; }
    bool IsNumber() const { return type_ == Type::Number; }
    bool IsString() const { return type_ == Type::String; }
    bool IsArray() const { return type_ == Type::Array; }
    bool IsObject() const { return type_ == Type::Object; }

    bool AsBool() const { return bool_; }
    double AsNumber() const { return num_; }
    const std::string& AsString() const { return str_; }

    // ---- object access ----
    // Returns nullptr when the member is missing or `this` is not an object.
    const Value* Get(const std::string& key) const;
    bool Has(const std::string& key) const { return Get(key) != nullptr; }
    std::vector<std::string> Keys() const;
    // Returns the member (creating it as Null when absent / not an object).
    Value& GetOrCreate(const std::string& key);

    // ---- array access ----
    size_t Size() const { return arr_.size(); }
    const Value& At(size_t i) const { return arr_[i]; }
    const std::vector<Value>& Items() const { return arr_; }
    void Push(Value v);
    // Removes the first array element whose string value equals `s`.
    void RemoveString(const std::string& s);

    void Set(const std::string& key, Value v);

private:
    Type type_ = Type::Null;
    bool bool_ = false;
    double num_ = 0;
    std::string str_;
    std::vector<Value> arr_;
    std::vector<std::pair<std::string, Value>> obj_; // ordered members
};

// Parses `text` (a complete JSON document). Returns false on syntax error
// (leaving *out untouched).
bool Parse(const std::string& text, Value* out);

// Serializes a value. `pretty` indents with 2 spaces (used when rewriting
// package.json); compact mode is for debugging only.
std::string Stringify(const Value& v, bool pretty = true);

} // namespace Json
} // namespace dsh
