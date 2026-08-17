#include "server_manager.h"

#include "node_runtime_manager.h"
#include "settings.h"
#include "util.h"

#include <winsock2.h>
#include <ws2tcpip.h>
#include <winhttp.h>

#include <chrono>
#include <filesystem>
#include <system_error>
#include <thread>

#pragma comment(lib, "ws2_32.lib")

namespace dsh {
namespace ServerManager {

namespace {

Settings g_settings;
HANDLE g_job = nullptr;
HANDLE g_process = nullptr;
bool g_reusing = false;

std::wstring LogFilePath() {
    return JoinPath(GetTempDir(), L"DSHWebView-dsh.log");
}

std::wstring ResolveNpxPath(const std::wstring& requested) {
    if (requested == L"npx") {
        auto npx = NodeRuntimeManager::NpxPath();
        if (!npx.empty()) return npx;
    }
    return requested;
}

// Locates a locally installed @deepseek-ai/dsh package in the npx cache or
// the global npm modules dir. Returns the package directory (the one holding
// lib/bin.js), preferring the most recently installed copy. Empty when absent.
std::wstring FindCachedDshDir() {
    std::vector<std::wstring> roots{
        JoinPath(GetUserProfile(), L".npm\\_npx"),
        JoinPath(GetLocalAppData(), L"npm-cache\\_npx"),
        JoinPath(GetUserProfile(), L"AppData\\Roaming\\npm\\node_modules\\@deepseek-ai\\dsh"),
    };

    std::wstring best;
    std::filesystem::file_time_type bestTime{};
    bool haveBest = false;

    for (auto& root : roots) {
        if (root.empty() || !DirExists(root)) continue;
        std::error_code ec;
        auto it = std::filesystem::recursive_directory_iterator(
            root, std::filesystem::directory_options::skip_permission_denied, ec);
        auto end = std::filesystem::recursive_directory_iterator{};
        while (!ec && it != end) {
            if (it->is_directory() &&
                it->path().filename().wstring() == L"dsh" &&
                it->path().parent_path().filename().wstring() == L"@deepseek-ai") {
                std::wstring dir = it->path().wstring();
                if (FileExists(JoinPath(dir, L"lib\\bin.js"))) {
                    std::error_code ec2;
                    auto t = std::filesystem::last_write_time(JoinPath(dir, L"package.json"), ec2);
                    if (!ec2 && (!haveBest || t > bestTime)) {
                        bestTime = t;
                        best = dir;
                        haveBest = true;
                    }
                }
            }
            it.increment(ec);
        }
    }
    return best;
}

} // namespace

void Initialize(const Settings& settings) { g_settings = settings; }

std::wstring PrepareCommandLine() {
    if (g_settings.command.empty()) {
        throw std::runtime_error("server command is empty");
    }

    std::vector<std::wstring> argv = g_settings.command;

    // When the command is the standard `npx --yes @deepseek-ai/dsh web ...`
    // form and a cached copy of @deepseek-ai/dsh exists, run it directly with
    // node. This skips npx's online registry revalidation, so startup never
    // waits on the network. A newer release is surfaced later by the
    // background update check (DshUpdateManager) running on its own thread.
    bool hasYes = argv.size() >= 3 && argv[1] == L"--yes";
    bool defaultNpxForm = argv.size() >= 2 &&
                          (argv[0] == L"npx" || argv[0] == L"npx.cmd") &&
                          (argv[1] == L"@deepseek-ai/dsh" ||
                           (hasYes && argv[2] == L"@deepseek-ai/dsh"));
    if (defaultNpxForm) {
        auto dshDir = FindCachedDshDir();
        auto node = NodeRuntimeManager::NodePath();
        auto bin = JoinPath(dshDir, L"lib\\bin.js");
        if (!dshDir.empty() && !node.empty() && FileExists(bin)) {
            std::wstring direct = QuoteArg(node) + L" " + QuoteArg(bin);
            size_t start = hasYes ? 3 : 2;  // skip npx [--yes] @deepseek-ai/dsh
            for (size_t i = start; i < argv.size(); i++) {
                direct += L" " + QuoteArg(argv[i]);
            }
            return direct;
        }
    }

    // When the command starts with npx, resolve it to a concrete executable
    // so we don't depend on PATH (which a child process inherits anyway).
    if (!argv.empty() && (argv[0] == L"npx" || argv[0] == L"npx.cmd")) {
        argv[0] = ResolveNpxPath(L"npx");
    }

    std::wstring line;
    for (auto& arg : argv) {
        if (!line.empty()) line += L" ";
        line += QuoteArg(arg);
    }
    return line;
}

bool Start() {
    Stop();

    // Reuse an already-running dsh instance on the configured port (e.g. a
    // leftover from a previous launch) instead of spawning a second, empty
    // instance — the remote app would see no sessions on it.
    if (LooksLikeDshWeb(g_settings.host, g_settings.port)) {
        g_reusing = true;
        return true;
    }
    g_reusing = false;

    std::wstring cmd = PrepareCommandLine();
    if (cmd.empty()) return false;

    // Kill the whole process tree when we exit / on Stop().
    g_job = CreateJobObjectW(nullptr, nullptr);
    if (g_job) {
        JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits{};
        limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        SetInformationJobObject(g_job, JobObjectExtendedLimitInformation, &limits, sizeof(limits));
    }

    // Child environment: inherit, then apply npm/dsh overrides.
    EnvGuard env;
    env.SetIfAbsent(L"npm_config_yes", L"true");
    env.SetIfAbsent(L"npm_config_fund", L"false");
    env.SetIfAbsent(L"npm_config_update_notifier", L"false");
    env.SetIfAbsent(L"npm_config_registry", NodeRuntimeManager::NpmRegistryUrl());

    // npx.cmd locates `node` via PATH; make the resolved node bin dir visible.
    auto nodeBin = NodeRuntimeManager::BinDirectoryFromNodePath();
    if (!nodeBin.empty()) {
        auto existingPath = GetEnv(L"Path");
        if (existingPath.find(nodeBin) == std::wstring::npos) {
            env.Set(L"Path", nodeBin + L";" + existingPath);
        }
    }

    auto existingNodeOptions = GetEnv(L"NODE_OPTIONS");
    std::wstring nodeOptions = existingNodeOptions;
    if (nodeOptions.find(L"--dns-result-order") == std::wstring::npos) {
        if (!nodeOptions.empty()) nodeOptions += L" ";
        nodeOptions += L"--dns-result-order=ipv4first";
    }
    env.Set(L"NODE_OPTIONS", nodeOptions);

    // Redirect stdout/stderr to a log file for diagnosis.
    SECURITY_ATTRIBUTES sa{};
    sa.nLength = sizeof(sa);
    sa.bInheritHandle = TRUE;
    HANDLE logFile = CreateFileW(LogFilePath().c_str(), GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE,
                                 &sa, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);

    STARTUPINFOW si{};
    si.cb = sizeof(si);
    if (logFile != INVALID_HANDLE_VALUE) {
        si.dwFlags = STARTF_USESTDHANDLES;
        si.hStdOutput = logFile;
        si.hStdError = logFile;
        si.hStdInput = GetStdHandle(STD_INPUT_HANDLE);
    }

    PROCESS_INFORMATION pi{};
    wchar_t* mutableCmd = _wcsdup(cmd.c_str());
    bool created = CreateProcessW(nullptr, mutableCmd, nullptr, nullptr, TRUE, CREATE_NO_WINDOW,
                                  nullptr, nullptr, &si, &pi);
    free(mutableCmd);
    if (logFile != INVALID_HANDLE_VALUE) CloseHandle(logFile);

    if (!created) {
        if (g_job) { CloseHandle(g_job); g_job = nullptr; }
        return false;
    }

    g_process = pi.hProcess;
    CloseHandle(pi.hThread);
    if (g_job) {
        AssignProcessToJobObject(g_job, g_process);
    }
    return true;
}

bool IsRunning() {
    if (!g_process) return false;
    DWORD code = 0;
    if (!GetExitCodeProcess(g_process, &code)) return false;
    return code == STILL_ACTIVE;
}

// True when the port already serves a web page (treated as an existing dsh
// instance worth reusing). Uses a plain HTTP GET with short timeouts.
bool LooksLikeDshWeb(const std::wstring& host, unsigned short port) {
    HINTERNET session = WinHttpOpen(L"DSHWebView", WINHTTP_ACCESS_TYPE_DEFAULT_PROXY,
                                    nullptr, nullptr, 0);
    if (!session) return false;
    HINTERNET conn = WinHttpConnect(session, host.c_str(), port, 0);
    if (!conn) {
        WinHttpCloseHandle(session);
        return false;
    }
    HINTERNET req = WinHttpOpenRequest(conn, L"GET", L"/", nullptr, nullptr,
                                       nullptr, WINHTTP_FLAG_BYPASS_PROXY_CACHE);
    if (!req) {
        WinHttpCloseHandle(conn);
        WinHttpCloseHandle(session);
        return false;
    }
    bool ok = false;
    if (WinHttpSendRequest(req, nullptr, 0, nullptr, 0, 0, 0) &&
        WinHttpReceiveResponse(req, nullptr)) {
        DWORD status = 0;
        DWORD statusLen = sizeof(status);
        if (WinHttpQueryHeaders(req,
                                WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
                                WINHTTP_HEADER_NAME_BY_INDEX, &status, &statusLen, nullptr) &&
            status == 200) {
            wchar_t ctype[128] = {};
            DWORD ctypeLen = sizeof(ctype);
            if (WinHttpQueryHeaders(req, WINHTTP_QUERY_CONTENT_TYPE,
                                    WINHTTP_HEADER_NAME_BY_INDEX, ctype, &ctypeLen, nullptr)) {
                ok = wcsstr(ctype, L"text/html") != nullptr;
            }
        }
    }
    WinHttpCloseHandle(req);
    WinHttpCloseHandle(conn);
    WinHttpCloseHandle(session);
    return ok;
}

void Stop() {
    if (g_process && g_job) {
        TerminateJobObject(g_job, 0);
    }
    if (g_process) {
        WaitForSingleObject(g_process, 5000);
        CloseHandle(g_process);
        g_process = nullptr;
    }
    if (g_job) {
        CloseHandle(g_job);
        g_job = nullptr;
    }
}

unsigned short Port() { return g_settings.port; }
std::wstring Host() { return g_settings.host; }
std::wstring Url() { return g_settings.Url(); }

bool WaitUntilReady(int timeoutMs, const std::function<void()>& onWaiting) {
    auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(timeoutMs);

    WSADATA wsa{};
    if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0) return false;

    bool ready = false;
    while (std::chrono::steady_clock::now() < deadline) {
        if (!IsRunning() && !g_reusing) break;

        SOCKET sock = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
        if (sock != INVALID_SOCKET) {
            sockaddr_in addr{};
            addr.sin_family = AF_INET;
            addr.sin_port = htons(g_settings.port);
            addr.sin_addr.s_addr = htonl(0x7F000001); // 127.0.0.1
            if (connect(sock, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) == 0) {
                closesocket(sock);
                ready = true;
                break;
            }
            closesocket(sock);
        }

        if (onWaiting) onWaiting();
        std::this_thread::sleep_for(std::chrono::milliseconds(250));
    }

    WSACleanup();
    return ready;
}

} // namespace ServerManager
} // namespace dsh
