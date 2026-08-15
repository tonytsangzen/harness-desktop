#include "util.h"

#include <shlobj.h>
#include <winreg.h>

#include <fstream>
#include <iterator>
#include <sstream>

namespace dsh {

std::wstring GetEnv(const wchar_t* name) {
    DWORD size = GetEnvironmentVariableW(name, nullptr, 0);
    if (size == 0) return {};
    std::wstring value(size, L'\0');
    GetEnvironmentVariableW(name, value.data(), static_cast<DWORD>(value.size()));
    value.pop_back(); // trailing NUL
    return value;
}

void EnvGuard::Set(const std::wstring& name, const std::wstring& value) {
    Entry entry;
    entry.name = name;
    DWORD size = GetEnvironmentVariableW(name.c_str(), nullptr, 0);
    if (size > 0) {
        entry.existed = true;
        entry.oldValue.assign(size - 1, L'\0');
        GetEnvironmentVariableW(name.c_str(), entry.oldValue.data(), size);
    }
    entries_.push_back(std::move(entry));
    SetEnvironmentVariableW(name.c_str(), value.c_str());
}

void EnvGuard::SetIfAbsent(const std::wstring& name, const std::wstring& value) {
    if (!GetEnv(name.c_str()).empty()) return;
    Set(name, value);
}

EnvGuard::~EnvGuard() {
    for (auto it = entries_.rbegin(); it != entries_.rend(); ++it) {
        SetEnvironmentVariableW(it->name.c_str(), it->existed ? it->oldValue.c_str() : nullptr);
    }
}

static std::wstring KnownFolder(const KNOWNFOLDERID& id) {
    PWSTR path = nullptr;
    if (SUCCEEDED(SHGetKnownFolderPath(id, KF_FLAG_DEFAULT, nullptr, &path)) && path) {
        std::wstring result(path);
        CoTaskMemFree(path);
        return result;
    }
    return {};
}

std::wstring GetProgramFiles() { return KnownFolder(FOLDERID_ProgramFiles); }
std::wstring GetLocalAppData() { return KnownFolder(FOLDERID_LocalAppData); }
std::wstring GetUserProfile() { return KnownFolder(FOLDERID_Profile); }
std::wstring GetDownloadsFolder() { return KnownFolder(FOLDERID_Downloads); }

std::wstring GetTempDir() {
    wchar_t buf[MAX_PATH];
    GetTempPathW(MAX_PATH, buf);
    std::wstring s(buf);
    if (!s.empty() && s.back() == L'\\') s.pop_back();
    return s;
}

bool FileExists(const std::wstring& path) {
    DWORD attr = GetFileAttributesW(path.c_str());
    return attr != INVALID_FILE_ATTRIBUTES && !(attr & FILE_ATTRIBUTE_DIRECTORY);
}

bool DirExists(const std::wstring& path) {
    DWORD attr = GetFileAttributesW(path.c_str());
    return attr != INVALID_FILE_ATTRIBUTES && (attr & FILE_ATTRIBUTE_DIRECTORY);
}

std::wstring JoinPath(const std::wstring& a, const std::wstring& b) {
    if (a.empty()) return b;
    if (a.back() == L'\\' || a.back() == L'/') return a + b;
    return a + L"\\" + b;
}

std::wstring DirName(const std::wstring& path) {
    auto pos = path.find_last_of(L"\\/");
    if (pos == std::wstring::npos) return {};
    if (pos == 0) return L"\\";
    return path.substr(0, pos);
}

std::wstring BaseName(const std::wstring& path) {
    auto pos = path.find_last_of(L"\\/");
    return pos == std::wstring::npos ? path : path.substr(pos + 1);
}

std::wstring MakeUniquePath(const std::wstring& path) {
    auto dir = DirName(path);
    auto name = BaseName(path);
    auto dot = name.find_last_of(L'.');
    std::wstring stem = dot == std::wstring::npos ? name : name.substr(0, dot);
    std::wstring ext = dot == std::wstring::npos ? L"" : name.substr(dot);
    for (int i = 1; i < 1000; ++i) {
        std::wstring candidate = JoinPath(dir, stem + L" (" + std::to_wstring(i) + L")" + ext);
        if (!FileExists(candidate)) return candidate;
    }
    return path;
}

bool EndsWithIgnoreCase(const std::wstring& s, const std::wstring& suffix) {
    if (suffix.size() > s.size()) return false;
    return CompareStringOrdinal(s.c_str() + (s.size() - suffix.size()), static_cast<int>(suffix.size()),
                                suffix.c_str(), static_cast<int>(suffix.size()), TRUE) == CSTR_EQUAL;
}

std::vector<std::wstring> SplitWhitespace(const std::wstring& s) {
    std::vector<std::wstring> tokens;
    std::wstring current;
    for (wchar_t c : s) {
        if (c == L' ' || c == L'\t') {
            if (!current.empty()) {
                tokens.push_back(current);
                current.clear();
            }
        } else {
            current.push_back(c);
        }
    }
    if (!current.empty()) tokens.push_back(current);
    return tokens;
}

std::wstring ReadFileText(const std::wstring& path) {
    std::wifstream in(path, std::ios::binary);
    if (!in) return {};
    std::wstring content((std::istreambuf_iterator<wchar_t>(in)), std::istreambuf_iterator<wchar_t>());
    return content;
}

bool ReadFileBytes(const std::wstring& path, std::string& out) {
    std::ifstream in(path, std::ios::binary);
    if (!in) return false;
    out.assign((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
    return true;
}

std::wstring QuoteArg(const std::wstring& s) {
    if (s.find(L' ') == std::wstring::npos) return s;
    return L"\"" + s + L"\"";
}

void BroadcastPathChanged() {
    SendMessageTimeoutW(HWND_BROADCAST, WM_SETTINGCHANGE, 0,
                        reinterpret_cast<LPARAM>(L"Environment"), SMTO_ABORTIFHUNG, 5000, nullptr);
}

} // namespace dsh
