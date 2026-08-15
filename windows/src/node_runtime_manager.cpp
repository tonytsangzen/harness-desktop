#include "node_runtime_manager.h"

#include "http.h"
#include "json.h"
#include "util.h"

#include <winreg.h>
#include <shellapi.h>

#include <cctype>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <random>

namespace dsh {
namespace NodeRuntimeManager {

namespace {

const wchar_t kFallbackVersion[] = L"v22.14.0";

bool IsMainlandChina() {
    DYNAMIC_TIME_ZONE_INFORMATION tzi{};
    if (GetDynamicTimeZoneInformation(&tzi) == TIME_ZONE_ID_INVALID) return false;
    // Bias is minutes WEST of UTC; China is UTC+8 -> bias = -480.
    double hours = -static_cast<double>(tzi.Bias) / 60.0;
    return hours >= 7.5 && hours <= 8.5;
}

std::wstring FindOnPath(const std::wstring& name) {
    auto path = GetEnv(L"Path");
    size_t start = 0;
    while (start <= path.size()) {
        auto end = path.find(L';', start);
        std::wstring dir = path.substr(start, end == std::wstring::npos ? std::wstring::npos : end - start);
        if (!dir.empty()) {
            for (const wchar_t* ext : { L".exe", L".cmd", L".bat", L"" }) {
                std::wstring full = JoinPath(dir, name + ext);
                if (FileExists(full)) return full;
            }
        }
        if (end == std::wstring::npos) break;
        start = end + 1;
    }
    return {};
}

std::vector<std::wstring> BinaryCandidateDirs() {
    std::vector<std::wstring> list{
        JoinPath(GetProgramFiles(), L"nodejs"),
        JoinPath(GetLocalAppData(), L"Programs\\nodejs"),
        JoinPath(GetUserProfile(), L".local\\bin"),
        JoinPath(GetUserProfile(), L"AppData\\Roaming\\npm"),
    };
    // nvm-windows versions live under AppData\Roaming\nvm\<version>
    auto nvmRoot = JoinPath(GetUserProfile(), L"AppData\\Roaming\\nvm");
    if (DirExists(nvmRoot)) {
        for (auto& entry : std::filesystem::directory_iterator(nvmRoot)) {
            if (entry.is_directory()) list.push_back(JoinPath(entry.path().wstring(), L"node.exe"));
        }
    }
    return list;
}

std::wstring ResolveLatestLTS() {
    std::string json;
    auto url = DistBase() + L"/index.json";
    if (HttpGetString(url, json)) {
        std::string version;
        if (JsonFirstLTSVersion(json, version) && !version.empty()) {
            return std::wstring(version.begin(), version.end());
        }
    }
    return kFallbackVersion;
}

// Extracts a .zip using the Windows 10 1809+ built-in tar (bsdtar).
bool ExtractZip(const std::wstring& zipPath, const std::wstring& destDir) {
    std::wstring cmd = L"tar.exe -xf " + QuoteArg(zipPath) + L" -C " + QuoteArg(destDir);
    STARTUPINFOW si{};
    si.cb = sizeof(si);
    PROCESS_INFORMATION pi{};
    if (!CreateProcessW(nullptr, cmd.data(), nullptr, nullptr, FALSE, CREATE_NO_WINDOW, nullptr, nullptr, &si, &pi)) {
        return false;
    }
    CloseHandle(pi.hThread);
    WaitForSingleObject(pi.hProcess, 10 * 60 * 1000);
    DWORD code = 0;
    GetExitCodeProcess(pi.hProcess, &code);
    CloseHandle(pi.hProcess);
    return code == 0;
}

void CopyDirectoryRecursive(const std::wstring& src, const std::wstring& dst) {
    std::filesystem::create_directories(dst);
    for (auto& entry : std::filesystem::directory_iterator(src)) {
        auto target = JoinPath(dst, entry.path().filename().wstring());
        if (entry.is_directory()) {
            CopyDirectoryRecursive(entry.path().wstring(), target);
        } else {
            std::error_code ec;
            std::filesystem::copy_file(entry.path(), target, std::filesystem::copy_options::overwrite_existing, ec);
        }
    }
}

std::wstring RandomGuid() {
    std::random_device rd;
    std::mt19937 gen(rd());
    std::uniform_int_distribution<int> dist(0, 15);
    const wchar_t* hex = L"0123456789abcdef";
    std::wstring g;
    for (int i = 0; i < 32; i++) g += hex[dist(gen)];
    return g;
}

// Append installDir to the process PATH and persist to HKCU\Environment.
void AddToUserPath(const std::wstring& installDir) {
    auto envPath = GetEnv(L"Path");
    bool found = false;
    size_t pos = 0;
    while (pos <= envPath.size()) {
        auto end = envPath.find(L';', pos);
        std::wstring entry = envPath.substr(pos, end == std::wstring::npos ? std::wstring::npos : end - pos);
        if (!entry.empty() && _wcsicmp(entry.c_str(), installDir.c_str()) == 0) { found = true; break; }
        if (end == std::wstring::npos) break;
        pos = end + 1;
    }
    if (!found) {
        SetEnvironmentVariableW(L"Path", (installDir + L";" + envPath).c_str());
    }

    // Persist to the user environment.
    HKEY key = nullptr;
    if (RegOpenKeyExW(HKEY_CURRENT_USER, L"Environment", 0, KEY_READ | KEY_WRITE, &key) != ERROR_SUCCESS) {
        return;
    }
    std::wstring existing;
    DWORD size = 0;
    DWORD type = REG_EXPAND_SZ;
    if (RegQueryValueExW(key, L"Path", nullptr, &type, nullptr, &size) == ERROR_SUCCESS && size > 0) {
        std::vector<wchar_t> buf(size / sizeof(wchar_t) + 1);
        if (RegQueryValueExW(key, L"Path", nullptr, &type, reinterpret_cast<LPBYTE>(buf.data()),
                             &size) == ERROR_SUCCESS) {
            existing.assign(buf.data());
        }
    }
    bool alreadyInUserPath = false;
    pos = 0;
    while (pos <= existing.size()) {
        auto end = existing.find(L';', pos);
        std::wstring entry = existing.substr(pos, end == std::wstring::npos ? std::wstring::npos : end - pos);
        if (!entry.empty() && _wcsicmp(entry.c_str(), installDir.c_str()) == 0) { alreadyInUserPath = true; break; }
        if (end == std::wstring::npos) break;
        pos = end + 1;
    }
    if (!alreadyInUserPath) {
        std::wstring updated = existing.empty() ? installDir : existing + L";" + installDir;
        RegSetValueExW(key, L"Path", 0, REG_EXPAND_SZ,
                       reinterpret_cast<const BYTE*>(updated.c_str()),
                       static_cast<DWORD>((updated.size() + 1) * sizeof(wchar_t)));
    }
    RegCloseKey(key);
    BroadcastPathChanged();
}

} // namespace

bool RuntimeAvailable() { return !NodePath().empty() && !NpxPath().empty(); }

std::wstring NodePath() {
    auto onPath = FindOnPath(L"node");
    if (!onPath.empty()) return onPath;
    for (auto& dir : BinaryCandidateDirs()) {
        auto full = EndsWithIgnoreCase(dir, L"node.exe") ? dir : JoinPath(dir, L"node.exe");
        if (FileExists(full)) return full;
    }
    return {};
}

std::wstring NpxPath() {
    auto onPath = FindOnPath(L"npx");
    if (!onPath.empty()) return onPath;
    auto node = NodePath();
    if (node.empty()) return {};
    auto binDir = DirName(node);
    if (!binDir.empty()) {
        auto npx = JoinPath(binDir, L"npx.cmd");
        if (FileExists(npx)) return npx;
        npx = JoinPath(binDir, L"npx.exe");
        if (FileExists(npx)) return npx;
    }
    return {};
}

std::wstring BinDirectoryFromNodePath() {
    auto node = NodePath();
    return node.empty() ? std::wstring{} : DirName(node);
}

bool IsMainlandChinaTimeZone() { return IsMainlandChina(); }

std::wstring DistBase() {
    return IsMainlandChina() ? L"https://registry.npmmirror.com/-/binary/node"
                             : L"https://nodejs.org/dist";
}

std::wstring NpmRegistryUrl() {
    return IsMainlandChina() ? L"https://registry.npmmirror.com"
                             : L"https://registry.npmjs.org";
}

std::wstring ArchName() {
    SYSTEM_INFO info{};
    GetNativeSystemInfo(&info);
    switch (info.wProcessorArchitecture) {
        case PROCESSOR_ARCHITECTURE_ARM64: return L"arm64";
        default: return L"x64";
    }
}

std::wstring InstallDir() { return JoinPath(GetLocalAppData(), L"Programs\\nodejs"); }

bool Provide(const std::function<void(State, double)>& onState) {
    if (RuntimeAvailable()) {
        onState(State::Done, 0);
        return true;
    }

    auto version = ResolveLatestLTS();
    auto arch = ArchName();
    auto downloadUrl = DistBase() + L"/" + version + L"/node-" + version + L"-win-" + arch + L".zip";
    auto zipPath = JoinPath(GetTempDir(), L"node-" + version + L"-win-" + arch + L".zip");

    onState(State::Downloading, -1);
    bool ok = HttpGetToFile(downloadUrl, zipPath, [&](long long received, long long total) {
        double progress = total > 0 ? static_cast<double>(received) / total : -1.0;
        if (progress < 0) progress = -1.0;
        else if (progress > 1.0) progress = 1.0;
        onState(State::Downloading, progress);
    });
    if (!ok) {
        onState(State::Failed, 0);
        return false;
    }

    onState(State::Installing, -1);
    auto installDir = InstallDir();
    std::error_code ec;
    std::filesystem::remove_all(installDir, ec);
    std::filesystem::create_directories(installDir, ec);

    auto extractDir = JoinPath(GetTempDir(), L"node-extract-" + RandomGuid());
    std::filesystem::create_directories(extractDir, ec);
    bool extractOk = ExtractZip(zipPath, extractDir);
    if (extractOk) {
        auto extracted = JoinPath(extractDir, L"node-" + version + L"-win-" + arch);
        if (DirExists(extracted)) {
            CopyDirectoryRecursive(extracted, installDir);
        }
    }
    std::filesystem::remove_all(extractDir, ec);
    std::filesystem::remove(zipPath, ec);

    if (!extractOk) {
        onState(State::Failed, 0);
        return false;
    }

    if (RuntimeAvailable()) {
        onState(State::Done, 0);
        return true;
    }

    onState(State::Failed, 0);
    return false;
}

} // namespace NodeRuntimeManager
} // namespace dsh
