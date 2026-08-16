#include "update_manager.h"

#include "util.h"

#include <libsoup/soup.h>

#include <algorithm>
#include <cstdio>
#include <vector>

#include <sys/stat.h>

namespace dsh {
namespace UpdateManager {

namespace {

// Extracts the value of the first `"version": "x.y.z"` match.
std::string ExtractVersion(const std::string& json) {
    const std::string key = "\"version\"";
    size_t pos = json.find(key);
    if (pos == std::string::npos) return {};
    pos = json.find('"', pos + key.size());
    if (pos == std::string::npos) return {};
    size_t end = json.find('"', pos + 1);
    if (end == std::string::npos) return {};
    return json.substr(pos + 1, end - pos - 1);
}

} // namespace

std::string LocalVersion() {
    // Scan the npx cache for the newest @deepseek-ai/dsh package.json.
    std::string home = GetEnv("HOME");
    if (home.empty()) return {};
    std::string npx = home + "/.npm/_npx";

    std::vector<std::string> entries;
    GDir* dir = g_dir_open(npx.c_str(), 0, nullptr);
    if (!dir) return {};
    const char* name = nullptr;
    while ((name = g_dir_read_name(dir)) != nullptr) {
        entries.push_back(npx + "/" + name);
    }
    g_dir_close(dir);

    std::string bestVersion;
    time_t bestMtime = 0;
    for (const auto& entry : entries) {
        std::string pkg = entry + "/node_modules/@deepseek-ai/dsh/package.json";
        struct stat st{};
        if (stat(pkg.c_str(), &st) != 0) continue;
        std::string json = ReadFileText(pkg);
        std::string version = ExtractVersion(json);
        if (version.empty()) continue;
        if (st.st_mtime >= bestMtime) {
            bestMtime = st.st_mtime;
            bestVersion = version;
        }
    }
    return bestVersion;
}

std::string LatestVersion() {
    GError* error = nullptr;
    SoupSession* session = soup_session_new();
    SoupMessage* msg = soup_message_new(
        "GET", "https://registry.npmjs.org/@deepseek-ai/dsh/latest");
    if (!msg) {
        g_object_unref(session);
        return {};
    }
    GBytes* bytes = soup_session_send_and_read(session, msg, nullptr, &error);
    std::string body;
    if (!error && bytes) {
        gsize len = 0;
        const gchar* data = static_cast<const gchar*>(g_bytes_get_data(bytes, &len));
        body.assign(data, len);
    }
    if (bytes) g_bytes_unref(bytes);
    g_object_unref(msg);
    g_object_unref(session);
    if (error) {
        g_error_free(error);
        return {};
    }
    return ExtractVersion(body);
}

bool UpdateAvailable(std::string* latest) {
    std::string local = LocalVersion();
    if (local.empty()) return false;
    std::string remote = LatestVersion();
    if (remote.empty()) return false;
    if (latest) *latest = remote;
    return VersionNewer(remote, local);
}

} // namespace UpdateManager
} // namespace dsh
