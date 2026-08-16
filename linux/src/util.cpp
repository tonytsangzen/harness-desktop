#include "util.h"

#include <glib.h>
#include <glib/gstdio.h>

#include <cstdlib>
#include <fstream>
#include <sstream>

namespace dsh {

std::string GetEnv(const std::string& name) {
    const char* v = std::getenv(name.c_str());
    return v ? std::string(v) : std::string();
}

void EnsureDir(const std::string& path) {
    g_mkdir_with_parents(path.c_str(), 0755);
}

std::string ConfigDir() {
    std::string base = GetEnv("XDG_CONFIG_HOME");
    if (base.empty()) {
        base = GetEnv("HOME");
        if (!base.empty()) base += "/.config";
    }
    if (base.empty()) base = "/tmp";
    std::string dir = base + "/deepseek-harness";
    EnsureDir(dir);
    return dir;
}

std::string GetDataDir() {
    std::string base = GetEnv("XDG_DATA_HOME");
    if (base.empty()) {
        base = GetEnv("HOME");
        if (!base.empty()) base += "/.local/share";
    }
    if (base.empty()) base = "/tmp";
    return base;
}

std::string ReadFileText(const std::string& path) {
    std::ifstream in(path, std::ios::binary);
    if (!in) return {};
    std::ostringstream ss;
    ss << in.rdbuf();
    return ss.str();
}

bool WriteFileText(const std::string& path, const std::string& text) {
    std::ofstream out(path, std::ios::binary | std::ios::trunc);
    if (!out) return false;
    out << text;
    return out.good();
}

static int VersionComponent(const std::string& v, size_t& pos) {
    int value = 0;
    while (pos < v.size() && v[pos] >= '0' && v[pos] <= '9') {
        value = value * 10 + (v[pos] - '0');
        ++pos;
    }
    return value;
}

bool VersionNewer(const std::string& a, const std::string& b) {
    size_t ia = 0, ib = 0;
    while (ia < a.size() || ib < b.size()) {
        int ca = VersionComponent(a, ia);
        int cb = VersionComponent(b, ib);
        if (ca != cb) return ca > cb;
        // skip separators
        while (ia < a.size() && (a[ia] == '.' || a[ia] == '-')) ++ia;
        while (ib < b.size() && (b[ib] == '.' || b[ib] == '-')) ++ib;
    }
    return false;
}

bool SystemLanguageIsChinese() {
    const char* const* langs = g_get_language_names();
    if (langs && langs[0]) {
        std::string first = langs[0];
        return first.compare(0, 2, "zh") == 0;
    }
    return false;
}

} // namespace dsh
