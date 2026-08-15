#include "http.h"

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <winhttp.h>

#include <cstdlib>
#include <fstream>

namespace dsh {

namespace {

struct ParsedUrl {
    std::wstring host;
    std::wstring path;
    INTERNET_PORT port = 80;
    bool secure = false;
};

bool ParseUrl(const std::wstring& url, ParsedUrl& out) {
    URL_COMPONENTSW comps{};
    comps.dwStructSize = sizeof(comps);

    wchar_t host[256] = L"";
    wchar_t path[4096] = L"";
    comps.lpszHostName = host;
    comps.dwHostNameLength = 256;
    comps.lpszUrlPath = path;
    comps.dwUrlPathLength = 4096;
    comps.lpszScheme = nullptr;
    comps.dwSchemeLength = 0;

    if (!WinHttpCrackUrl(url.c_str(), static_cast<DWORD>(url.size()), 0, &comps)) {
        return false;
    }
    out.host = comps.lpszHostName;
    out.path = comps.dwUrlPathLength ? comps.lpszUrlPath : L"/";
    out.port = comps.nPort;
    out.secure = comps.nScheme == INTERNET_SCHEME_HTTPS;
    return true;
}

bool HttpGet(const std::wstring& url, std::string& body, std::ostream* fileOut,
             const std::function<void(long long, long long)>& progress, long* statusOut) {
    ParsedUrl parsed;
    if (!ParseUrl(url, parsed)) return false;

    HINTERNET session = WinHttpOpen(L"DSHWebView/1.0", WINHTTP_ACCESS_TYPE_DEFAULT_PROXY,
                                    WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0);
    if (!session) return false;

    HINTERNET connect = WinHttpConnect(session, parsed.host.c_str(), parsed.port, 0);
    if (!connect) {
        WinHttpCloseHandle(session);
        return false;
    }

    DWORD flags = parsed.secure ? WINHTTP_FLAG_SECURE : 0;
    HINTERNET request = WinHttpOpenRequest(connect, L"GET", parsed.path.c_str(), nullptr,
                                           WINHTTP_NO_REFERER, WINHTTP_DEFAULT_ACCEPT_TYPES, flags);
    if (!request) {
        WinHttpCloseHandle(connect);
        WinHttpCloseHandle(session);
        return false;
    }

    bool ok = WinHttpSendRequest(request, WINHTTP_NO_ADDITIONAL_HEADERS, 0,
                                 WINHTTP_NO_REQUEST_DATA, 0, 0, 0);
    if (ok) ok = WinHttpReceiveResponse(request, nullptr);

    if (!ok) {
        WinHttpCloseHandle(request);
        WinHttpCloseHandle(connect);
        WinHttpCloseHandle(session);
        return false;
    }

    if (statusOut) {
        wchar_t statusBuf[16] = L"";
        DWORD statusSize = sizeof(statusBuf);
        *statusOut = 0;
        if (WinHttpQueryHeaders(request, WINHTTP_QUERY_STATUS_CODE, WINHTTP_HEADER_NAME_BY_INDEX,
                                statusBuf, &statusSize, WINHTTP_NO_HEADER_INDEX)) {
            *statusOut = _wtol(statusBuf);
        }
    }

    // Total length (may be -1).
    long long total = -1;
    {
        wchar_t lengthBuf[64] = L"";
        DWORD lengthSize = sizeof(lengthBuf);
        if (WinHttpQueryHeaders(request, WINHTTP_QUERY_CONTENT_LENGTH, WINHTTP_HEADER_NAME_BY_INDEX,
                                lengthBuf, &lengthSize, WINHTTP_NO_HEADER_INDEX)) {
            total = _wtoi64(lengthBuf);
        }
    }

    long long received = 0;
    const DWORD kBufferSize = 128 * 1024;
    std::string buffer(kBufferSize, '\0');
    bool success = true;

    for (;;) {
        DWORD available = 0;
        if (!WinHttpQueryDataAvailable(request, &available)) {
            success = false;
            break;
        }
        if (available == 0) break;

        DWORD read = 0;
        if (!WinHttpReadData(request, buffer.data(), available > kBufferSize ? kBufferSize : available, &read)) {
            success = false;
            break;
        }
        if (read == 0) break;

        if (fileOut) fileOut->write(buffer.data(), read);
        else body.append(buffer.data(), read);
        received += read;
        if (progress) progress(received, total);
    }

    WinHttpCloseHandle(request);
    WinHttpCloseHandle(connect);
    WinHttpCloseHandle(session);
    return success;
}

} // namespace

bool HttpGetToFile(const std::wstring& url, const std::wstring& destPath,
                   const std::function<void(long long, long long)>& progress, long* statusOut) {
    std::ofstream file(destPath, std::ios::binary | std::ios::trunc);
    if (!file) return false;
    std::string discard;
    bool ok = HttpGet(url, discard, &file, progress, statusOut);
    file.close();
    return ok;
}

bool HttpGetString(const std::wstring& url, std::string& out) {
    out.clear();
    return HttpGet(url, out, nullptr, nullptr, nullptr);
}

} // namespace dsh
