#include "dsh_update_manager.h"

#include "http.h"
#include "json.h"
#include "node_runtime_manager.h"
#include "util.h"

#include <filesystem>
#include <fstream>
#include <sstream>
#include <vector>

namespace dsh {
namespace DSHUpdateManager {

namespace {

int PartValue(const std::string& s, int index) {
    std::stringstream ss(s);
    std::string part;
    for (int i = 0; i <= index && std::getline(ss, part, '.'); i++) {
        if (i == index) {
            // Allow a trailing "-pre" / "beta" qualifier: ignore it.
            auto dash = part.find('-');
            if (dash != std::string::npos) part = part.substr(0, dash);
            return atoi(part.c_str());
        }
    }
    return 0;
}

std::vector<std::wstring> NPXCacheRoots() {
    std::vector<std::wstring> roots{
        JoinPath(GetUserProfile(), L".npm\\_npx"),
        JoinPath(GetLocalAppData(), L"npm-cache\\_npx"),
    };
    return roots;
}

// Path to the @deepseek-ai/dsh package.json in any npx cache root or global
// npm modules dir. Empty when absent.
std::wstring FindDshPackageJson() {
    std::vector<std::wstring> roots = NPXCacheRoots();
    roots.push_back(JoinPath(GetUserProfile(), L"AppData\\Roaming\\npm\\node_modules\\@deepseek-ai\\dsh"));

    for (auto& root : roots) {
        if (root.empty() || !DirExists(root)) continue;
        for (auto& entry : std::filesystem::recursive_directory_iterator(root, std::filesystem::directory_options::skip_permission_denied)) {
            if (entry.is_directory() && entry.path().filename() == L"dsh") {
                auto pkg = JoinPath(entry.path().wstring(), L"package.json");
                if (FileExists(pkg)) return pkg;
            }
        }
    }
    return {};
}

void ClearNpxCache() {
    for (auto& root : NPXCacheRoots()) {
        if (root.empty() || !DirExists(root)) continue;
        std::error_code ec;
        for (auto& entry : std::filesystem::recursive_directory_iterator(root, std::filesystem::directory_options::skip_permission_denied)) {
            if (entry.is_directory() && entry.path().filename() == L"dsh") {
                std::filesystem::remove_all(entry.path(), ec);
            }
        }
    }
}

} // namespace

int CompareVersions(const std::string& a, const std::string& b) {
    for (int i = 0; i < 4; i++) {
        int pa = PartValue(a, i);
        int pb = PartValue(b, i);
        if (pa != pb) return pa < pb ? -1 : 1;
    }
    return 0;
}

std::string LocalVersion() {
    auto pkg = FindDshPackageJson();
    if (pkg.empty()) return {};
    std::string utf8;
    if (!ReadFileBytes(pkg, utf8)) return {};
    std::string version;
    if (JsonGetString(utf8, "version", version)) return version;
    return {};
}

std::string FetchLatest() {
    auto url = NodeRuntimeManager::NpmRegistryUrl() + L"/@deepseek-ai/dsh/latest";
    std::string body;
    if (!HttpGetString(url, body)) return {};
    std::string version;
    if (JsonGetString(body, "version", version)) return version;
    return {};
}

bool LatestIfUpdateAvailable(std::string& latest) {
    auto local = LocalVersion();
    if (local.empty()) return false;
    latest = FetchLatest();
    if (latest.empty()) return false;
    return CompareVersions(latest, local) > 0;
}

bool RefreshToLatest(const std::function<void(Status)>& onStatus) {
    if (onStatus) onStatus(Status::Refreshing);

    auto npx = NodeRuntimeManager::NpxPath();
    if (npx.empty()) {
        if (onStatus) onStatus(Status::RefreshFailed);
        return false;
    }

    // Remove the cached package so npx reinstalls the requested version.
    ClearNpxCache();

    auto node = NodeRuntimeManager::NodePath();
    std::wstring cmd;
    if (!node.empty()) {
        auto npxCli = JoinPath(DirName(node), L"node_modules\\npm\\bin\\npx-cli.js");
        if (FileExists(npxCli)) {
            cmd = QuoteArg(node) + L" " + QuoteArg(npxCli) + L" --yes @deepseek-ai/dsh@latest --version";
        }
    }
    if (cmd.empty()) {
        cmd = QuoteArg(npx) + L" --yes @deepseek-ai/dsh@latest --version";
    }

    STARTUPINFOW si{};
    si.cb = sizeof(si);
    si.dwFlags = STARTF_USESTDHANDLES;
    si.hStdInput = GetStdHandle(STD_INPUT_HANDLE);

    PROCESS_INFORMATION pi{};
    wchar_t* mutableCmd = _wcsdup(cmd.c_str());
    bool created = CreateProcessW(nullptr, mutableCmd, nullptr, nullptr, FALSE, CREATE_NO_WINDOW,
                                  nullptr, nullptr, &si, &pi);
    free(mutableCmd);
    if (!created) {
        if (onStatus) onStatus(Status::RefreshFailed);
        return false;
    }
    CloseHandle(pi.hThread);
    WaitForSingleObject(pi.hProcess, 15 * 60 * 1000);
    DWORD code = 0;
    GetExitCodeProcess(pi.hProcess, &code);
    CloseHandle(pi.hProcess);

    bool ok = code == 0;
    if (onStatus) onStatus(ok ? Status::Refreshed : Status::RefreshFailed);
    return ok;
}

} // namespace DSHUpdateManager
} // namespace dsh
