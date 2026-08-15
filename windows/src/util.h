#pragma once

#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>

#include <string>
#include <vector>

namespace dsh {

// Returns the value of an environment variable, or empty string if unset.
std::wstring GetEnv(const wchar_t* name);

// Environment variable scoped setter: restores the previous value on destruction.
class EnvGuard {
public:
    void Set(const std::wstring& name, const std::wstring& value);
    void SetIfAbsent(const std::wstring& name, const std::wstring& value);
    ~EnvGuard();

private:
    struct Entry {
        std::wstring name;
        std::wstring oldValue;
        bool existed = false;
    };
    std::vector<Entry> entries_;
};

std::wstring GetProgramFiles();
std::wstring GetLocalAppData();
std::wstring GetUserProfile();
std::wstring GetTempDir();
std::wstring GetDownloadsFolder();

bool FileExists(const std::wstring& path);
bool DirExists(const std::wstring& path);

std::wstring JoinPath(const std::wstring& a, const std::wstring& b);
std::wstring DirName(const std::wstring& path);

std::wstring MakeUniquePath(const std::wstring& path);
std::wstring BaseName(const std::wstring& path);

bool EndsWithIgnoreCase(const std::wstring& s, const std::wstring& suffix);

// Splits on any whitespace, skipping empty tokens.
std::vector<std::wstring> SplitWhitespace(const std::wstring& s);

std::wstring ReadFileText(const std::wstring& path);

// Reads a file as raw bytes (UTF-8 for text files).
bool ReadFileBytes(const std::wstring& path, std::string& out);

// Quotes a string for a cmd / CreateProcess command line if it contains spaces.
std::wstring QuoteArg(const std::wstring& s);

// Broadcasts WM_SETTINGCHANGE so Explorer picks up a changed user PATH.
void BroadcastPathChanged();

} // namespace dsh
