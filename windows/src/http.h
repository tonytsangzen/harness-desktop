#pragma once

#include <functional>
#include <string>

namespace dsh {

// GET a URL and save the body to a file. `progress` receives (bytesReceived,
// totalBytes) where total may be -1 if unknown. Returns false on failure.
// When `statusOut` is non-null, it receives the HTTP status code (0 if
// unknown / connection failed).
bool HttpGetToFile(const std::wstring& url,
                   const std::wstring& destPath,
                   const std::function<void(long long received, long long total)>& progress,
                   long* statusOut = nullptr);

// GET a URL and return the body as text (UTF-8). Returns false on failure.
bool HttpGetString(const std::wstring& url, std::string& out);

} // namespace dsh
