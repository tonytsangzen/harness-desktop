#include "node_runtime_manager.h"

#include "util.h"

#include <libsoup/soup.h>

#include <climits>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <vector>

#include <sys/stat.h>
#include <sys/utsname.h>
#include <unistd.h>

namespace dsh {
namespace NodeRuntimeManager {

namespace {

constexpr const char* kFallbackVersion = "v22.14.0";

bool FileExists(const std::string& path) {
    struct stat st{};
    return stat(path.c_str(), &st) == 0 && S_ISREG(st.st_mode);
}

bool DirExists(const std::string& path) {
    struct stat st{};
    return stat(path.c_str(), &st) == 0 && S_ISDIR(st.st_mode);
}

void RemoveTree(const std::string& path) {
    std::error_code ec;
    std::filesystem::remove_all(path, ec);
}

// True for the UTC+8 China timezone (matches the Windows shell's heuristic).
bool IsMainlandChina() {
    std::string tz = GetEnv("TZ");
    if (!tz.empty()) {
        return tz.find("Asia/Shanghai") != std::string::npos ||
               tz.find("Asia/Chongqing") != std::string::npos ||
               tz.find("Asia/Urumqi") != std::string::npos;
    }
    std::string tzfile = ReadFileText("/etc/timezone");
    while (!tzfile.empty() && (tzfile.back() == '\n' || tzfile.back() == '\r')) tzfile.pop_back();
    if (!tzfile.empty()) {
        return tzfile == "Asia/Shanghai" || tzfile == "Asia/Chongqing" ||
               tzfile == "Asia/Urumqi";
    }
    char buf[PATH_MAX];
    ssize_t n = readlink("/etc/localtime", buf, sizeof(buf) - 1);
    if (n > 0) {
        buf[n] = '\0';
        std::string p(buf);
        return p.find("Asia/Shanghai") != std::string::npos;
    }
    return false;
}

std::string DistBase() {
    return IsMainlandChina() ? "https://registry.npmmirror.com/-/binary/node"
                             : "https://nodejs.org/dist";
}

std::string ArchName() {
    struct utsname u{};
    if (uname(&u) != 0) return "x64";
    std::string m = u.machine;
    if (m == "x86_64" || m == "amd64") return "x64";
    if (m == "aarch64" || m == "arm64") return "arm64";
    return "x64"; // best effort for anything else
}

std::string CacheDir() {
    std::string base = GetEnv("XDG_CACHE_HOME");
    if (base.empty()) {
        base = GetEnv("HOME");
        if (!base.empty()) base += "/.cache";
    }
    if (base.empty()) base = "/tmp";
    std::string dir = base + "/deepseek-harness";
    EnsureDir(dir);
    return dir;
}

// GET a URL and return the response body (empty on failure).
std::string HttpGetString(const std::string& url) {
    GError* error = nullptr;
    SoupSession* session = soup_session_new();
    SoupMessage* msg = soup_message_new("GET", url.c_str());
    std::string body;
    if (msg) {
        GBytes* bytes = soup_session_send_and_read(session, msg, nullptr, &error);
        if (!error && bytes) {
            gsize len = 0;
            const gchar* data = static_cast<const gchar*>(g_bytes_get_data(bytes, &len));
            body.assign(data, len);
        }
        if (bytes) g_bytes_unref(bytes);
        g_object_unref(msg);
    }
    g_object_unref(session);
    if (error) g_error_free(error);
    return body;
}

// GET a URL streaming into a file, reporting fraction [0,1] when the
// Content-Length is known.
bool HttpGetToFile(const std::string& url, const std::string& path,
                   const std::function<void(double)>& onProgress) {
    GError* error = nullptr;
    SoupSession* session = soup_session_new();
    SoupMessage* msg = soup_message_new("GET", url.c_str());
    if (!msg) {
        g_object_unref(session);
        return false;
    }
    FILE* fp = fopen(path.c_str(), "wb");
    if (!fp) {
        g_object_unref(msg);
        g_object_unref(session);
        return false;
    }
    GInputStream* stream = soup_session_send(session, msg, nullptr, &error);
    bool ok = false;
    if (!error && stream) {
        gint64 total = soup_message_headers_get_content_length(
            soup_message_get_response_headers(msg));
        gint64 got = 0;
        char buf[65536];
        while (true) {
            gssize n = g_input_stream_read(stream, buf, sizeof(buf), nullptr, &error);
            if (n < 0) break;
            if (n == 0) { ok = true; break; }
            if (fwrite(buf, 1, static_cast<size_t>(n), fp) != static_cast<size_t>(n)) break;
            got += n;
            if (onProgress && total > 0) onProgress(static_cast<double>(got) / total);
        }
    }
    if (stream) g_object_unref(stream);
    fclose(fp);
    g_object_unref(msg);
    g_object_unref(session);
    if (error) g_error_free(error);
    if (!ok) ::remove(path.c_str());
    return ok;
}

// First entry of nodejs.org/dist/index.json whose "lts" is a non-empty string.
std::string ResolveLatestLTS() {
    std::string json = HttpGetString(DistBase() + "/index.json");
    const std::string vkey = "\"version\":\"";
    size_t pos = 0;
    while ((pos = json.find(vkey, pos)) != std::string::npos) {
        size_t vs = pos + vkey.size();
        size_t ve = json.find('"', vs);
        if (ve == std::string::npos) break;
        std::string version = json.substr(vs, ve - vs);
        // The "lts" field of this entry: must come before the next entry.
        size_t lts = json.find("\"lts\":", ve);
        size_t next = json.find(vkey, ve);
        if (lts != std::string::npos && (next == std::string::npos || lts < next)) {
            size_t p = lts + 6; // skip the 6 chars of `"lts":`
            while (p < json.size() && (json[p] == ' ' || json[p] == '\t')) ++p;
            if (p < json.size() && json[p] == '"') return version; // "lts":"Codename"
        }
        pos = ve + 1;
    }
    return kFallbackVersion;
}

// Extracts a .tar.xz using the system tar (GNU tar with xz support).
bool ExtractTarXz(const std::string& archive, const std::string& dest) {
    std::vector<char*> argv{
        const_cast<char*>("tar"), const_cast<char*>("-xJf"),
        const_cast<char*>(archive.c_str()), const_cast<char*>("-C"),
        const_cast<char*>(dest.c_str()), nullptr};
    GError* error = nullptr;
    gint status = 0;
    bool ok = g_spawn_sync(nullptr, argv.data(), nullptr, G_SPAWN_SEARCH_PATH,
                           nullptr, nullptr, nullptr, nullptr, &status, &error);
    if (error) g_error_free(error);
    return ok && g_spawn_check_wait_status(status, nullptr);
}

} // namespace

std::string InstallDir() { return GetDataDir() + "/deepseek-harness/nodejs"; }

std::string BinDir() { return InstallDir() + "/bin"; }

bool RuntimeAvailable() {
    if (g_find_program_in_path("npx")) return true;
    if (g_find_program_in_path("node")) return true;
    return FileExists(BinDir() + "/npx") && FileExists(BinDir() + "/node");
}

void EnsureOnPath() {
    std::string bin = BinDir();
    if (bin.empty()) return;
    std::string path = GetEnv("PATH");
    size_t start = 0;
    while (start <= path.size()) {
        size_t end = path.find(':', start);
        std::string entry =
            path.substr(start, end == std::string::npos ? std::string::npos : end - start);
        if (entry == bin) return;
        if (end == std::string::npos) break;
        start = end + 1;
    }
    setenv("PATH", (bin + ":" + path).c_str(), 1);
}

std::string NpmRegistryUrl() {
    return IsMainlandChina() ? "https://registry.npmmirror.com"
                             : "https://registry.npmjs.org";
}

bool Provide(const ProgressFn& onState) {
    if (RuntimeAvailable()) {
        if (onState) onState(State::Done, 0);
        return true;
    }

    std::string version = ResolveLatestLTS();
    std::string arch = ArchName();
    std::string tarball = "node-" + version + "-linux-" + arch + ".tar.xz";
    std::string url = DistBase() + "/" + version + "/" + tarball;
    std::string cacheDir = CacheDir();
    std::string archive = cacheDir + "/" + tarball;

    if (onState) onState(State::Downloading, -1);
    bool ok = HttpGetToFile(url, archive, [&onState](double p) {
        if (onState) onState(State::Downloading, p);
    });
    if (!ok) {
        if (onState) onState(State::Failed, 0);
        return false;
    }

    if (onState) onState(State::Installing, -1);
    std::string extractDir = cacheDir + "/node-extract";
    RemoveTree(extractDir);
    EnsureDir(extractDir);
    ok = ExtractTarXz(archive, extractDir);
    if (ok) {
        std::string extracted = extractDir + "/" + tarball.substr(0, tarball.size() - 7); // drop ".tar.xz"
        if (DirExists(extracted)) {
            std::string installDir = InstallDir();
            RemoveTree(installDir);
            EnsureDir(GetDataDir() + "/deepseek-harness");
            if (rename(extracted.c_str(), installDir.c_str()) != 0) ok = false;
        } else {
            ok = false;
        }
    }
    RemoveTree(extractDir);
    ::remove(archive.c_str());

    if (ok && RuntimeAvailable()) {
        if (onState) onState(State::Done, 0);
        return true;
    }
    if (onState) onState(State::Failed, 0);
    return false;
}

} // namespace NodeRuntimeManager
} // namespace dsh
