#include "server_manager.h"

#include "node_runtime_manager.h"
#include "settings.h"
#include "util.h"

#include <gio/gio.h>
#include <libsoup/soup.h>

#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

#include <fcntl.h>
#include <sys/wait.h>
#include <unistd.h>

namespace dsh {
namespace ServerManager {

namespace {

const Settings* g_settings = nullptr;
unsigned short g_activePort = 0;
GPid g_childPid = 0;
int g_childWatchId = 0;
bool g_running = false;

void OnChildExited(GPid pid, int /*status*/, gpointer /*user_data*/) {
    g_spawn_close_pid(pid);
    g_childPid = 0;
    g_childWatchId = 0;
    g_running = false;
}

} // namespace

void Initialize(const Settings& settings) {
    g_settings = &settings;
    g_activePort = 0;
}

bool NodeAvailable(std::string* missingTool) {
    if (NodeRuntimeManager::RuntimeAvailable()) return true;
    if (missingTool) *missingTool = "node/npx";
    return false;
}

bool TcpProbe(const std::string& host, unsigned short port, int timeoutMs) {
    GError* error = nullptr;
    GSocketClient* client = g_socket_client_new();
    g_socket_client_set_timeout(client, timeoutMs);
    GSocketConnection* conn = g_socket_client_connect_to_host(
        client, host.c_str(), static_cast<guint16>(port), nullptr, &error);
    bool ok = conn != nullptr;
    if (conn) g_object_unref(conn);
    g_object_unref(client);
    if (error) g_error_free(error);
    return ok;
}

// True when the port already serves a web page (treated as an existing dsh
// instance worth reusing). Uses a plain HTTP GET with a short timeout.
bool LooksLikeDshWeb(const std::string& host, unsigned short port) {
    std::string url = "http://" + host + ":" + std::to_string(port) + "/";
    SoupSession* session = soup_session_new();
    SoupMessage* msg = soup_message_new("GET", url.c_str());
    guint status = soup_session_send_message(session, msg);
    const char* ctype = msg->response_headers
                            ? soup_message_headers_get_content_type(msg->response_headers)
                            : nullptr;
    bool ok = status == 200 && ctype && g_strrstr(ctype, "text/html") != nullptr;
    g_object_unref(msg);
    g_object_unref(session);
    return ok;
}

unsigned short ResolvePort(const Settings& settings) {
    // Prefer the configured port when free; otherwise walk up (never kill an
    // existing process — matching the macOS/Windows behavior). When the
    // configured port is busy AND already serves a web page, treat it as an
    // existing dsh instance and reuse it (the remote app then sees its
    // sessions instead of an empty new instance).
    unsigned short port = settings.port;
    if (TcpProbe(settings.host, port, 300) && LooksLikeDshWeb(settings.host, port)) {
        return port;
    }
    for (int tries = 0; tries < 100; ++tries, ++port) {
        if (port == 0) port = 1024;
        if (!TcpProbe(settings.host, port, 300)) return port;
    }
    return settings.port;
}

unsigned short ActivePort() { return g_activePort; }

std::string LogPath() {
    std::string base = GetEnv("XDG_CACHE_HOME");
    if (base.empty()) {
        base = GetEnv("HOME");
        if (!base.empty()) base += "/.cache";
    }
    if (base.empty()) base = "/tmp";
    EnsureDir(base + "/deepseek-harness");
    return base + "/deepseek-harness/dsh-server.log";
}

static std::string LogErrPath() { return LogPath() + ".err"; }

// fork + exec so the child can start its own process group (whole tree dies
// together on Stop) and get its stdio redirected to log files.
bool Start() {
    if (!g_settings) return false;
    if (g_running) return true;

    // Make the auto-installed runtime visible to execvp before checking.
    NodeRuntimeManager::EnsureOnPath();

    std::string missing;
    if (!NodeAvailable(&missing)) {
        g_printerr("dshwebview: node/npx not found on PATH (%s)\n", missing.c_str());
        return false;
    }

    g_activePort = ResolvePort(*g_settings);

    // Reusing an existing instance on the configured port: nothing to spawn.
    if (TcpProbe(g_settings->host, g_activePort, 300)) {
        g_running = true;
        return true;
    }

    std::vector<std::string> cmd;
    if (g_settings->customCommand) {
        cmd = g_settings->command;
    } else {
        cmd = g_settings->command;
        cmd.push_back("--host");
        cmd.push_back(g_settings->host);
        cmd.push_back("--port");
        cmd.push_back(std::to_string(g_activePort));
    }

    std::vector<char*> argv;
    for (auto& c : cmd) argv.push_back(const_cast<char*>(c.c_str()));
    argv.push_back(nullptr);

    std::string logPath = LogPath();
    std::string logErr = LogErrPath();

    pid_t pid = fork();
    if (pid < 0) {
        g_printerr("dshwebview: fork failed: %s\n", std::strerror(errno));
        return false;
    }
    if (pid == 0) {
        // Child: own process group + stdio → log files.
        setpgid(0, 0);
        // Point npm at the right registry (China mirror) and never prompt for
        // confirmation — npx would otherwise block forever on its interactive
        // "Ok to proceed? (y)" (mirrors the Windows shell's npm_config_yes).
        setenv("npm_config_registry", NodeRuntimeManager::NpmRegistryUrl().c_str(), 1);
        setenv("npm_config_yes", "true", 1);
        // Ensure no child ever blocks reading a terminal (GUI apps have none).
        int devnull = open("/dev/null", O_RDONLY);
        if (devnull >= 0) { dup2(devnull, STDIN_FILENO); close(devnull); }
        int out = open(logPath.c_str(), O_WRONLY | O_CREAT | O_TRUNC, 0644);
        int err = open(logErr.c_str(), O_WRONLY | O_CREAT | O_TRUNC, 0644);
        if (out >= 0) { dup2(out, STDOUT_FILENO); close(out); }
        if (err >= 0) { dup2(err, STDERR_FILENO); close(err); }
        execvp(argv[0], argv.data());
        // exec failed (e.g. npx missing): report on the log and exit (stderr
        // was already redirected to the log file above).
        fprintf(stderr, "dshwebview: exec failed: %s\n", std::strerror(errno));
        _exit(127);
    }

    g_childPid = pid;
    g_childWatchId = g_child_watch_add(pid, OnChildExited, nullptr);
    g_running = true;
    return true;
}

void Stop() {
    if (g_childWatchId) { g_source_remove(g_childWatchId); g_childWatchId = 0; }
    if (!g_running || g_childPid == 0) {
        g_running = false;
        g_childPid = 0;
        return;
    }
    // Terminate the whole process group so npx/node children die together.
    kill(-g_childPid, SIGTERM);
    for (int i = 0; i < 50 && g_running; ++i) g_usleep(100 * 1000);
    if (g_running) kill(-g_childPid, SIGKILL);
    g_running = false;
    g_childPid = 0;
}

bool IsRunning() { return g_running; }

} // namespace ServerManager
} // namespace dsh
