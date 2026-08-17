#define _USE_MATH_DEFINES
#include "main_window.h"

#ifndef APP_VERSION
#define APP_VERSION "1.0.9"
#endif

#include "dsh_update_manager.h"
#include "http.h"
#include "json.h"
#include "node_runtime_manager.h"
#include "resource.h"
#include "server_manager.h"
#include "settings.h"
#include "util.h"

#include "../../third_party/qrcodegen/qrcodegen.h"

#include <wrl/client.h>
#include <wrl/event.h>
#include <webview2.h>
#include <gdiplus.h>
#include <wincrypt.h>
#include <iphlpapi.h>

#include <shlobj.h>
#include <shobjidl.h>
#include <shellapi.h>
#include <dwmapi.h>
#include <winnls.h>

#include <cmath>
#include <cstdlib>
#include <memory>
#include <string>
#include <utility>
#include <vector>

namespace dsh {

using Microsoft::WRL::Callback;
using Microsoft::WRL::ComPtr;

namespace {

ComPtr<ICoreWebView2Environment> g_env;
ComPtr<ICoreWebView2Controller> g_controller;
ComPtr<ICoreWebView2_4> g_core;

const UINT kWM_OverlayStatus = WM_APP + 1;
const UINT kWM_OverlayProgress = WM_APP + 2;
const UINT kWM_DownloadStatus = WM_APP + 3;
const UINT kWM_ShowDownloadBar = WM_APP + 4;
const UINT kWM_HideDownloadBar = WM_APP + 5;
const UINT kWM_ServerReady = WM_APP + 6;
const UINT kWM_ServerFailed = WM_APP + 7;
const UINT kWM_UpdateAvailable = WM_APP + 8;
const UINT kWM_UpdateFinished = WM_APP + 9;
const UINT kWM_DownloadFailed = WM_APP + 10;
const UINT kWM_BridgeLine = WM_APP + 11;

const UINT_PTR kSpinnerTimer = 1;
const UINT_PTR kRegisterTimerId = 2;
const int kDownloadBarHeight = 48;
const UINT_PTR kIDM_PluginsMarket = 40001;
const UINT_PTR kIDM_ThemeSystem = 40002;
const UINT_PTR kIDM_ThemeLight = 40003;
const UINT_PTR kIDM_ThemeDark = 40004;
const UINT_PTR kIDM_LangZh = 40005;
const UINT_PTR kIDM_LangEn = 40006;
const UINT_PTR kIDM_LangSystem = 40007;
const UINT_PTR kIDM_FullScreen = 40008;
const UINT_PTR kIDM_MobileRemote = 40009;
const UINT_PTR kIDM_Settings = 40010;
const UINT_PTR kIDM_About = 40011;

const COLORREF kOverlayBg = RGB(0xFF, 0xFF, 0xFF);
const COLORREF kOverlayText = RGB(0x20, 0x20, 0x20);
const COLORREF kOverlayBgDark = RGB(0x1E, 0x1E, 0x1E);
const COLORREF kOverlayTextDark = RGB(0xE8, 0xE8, 0xE8);
const COLORREF kOverlayTrack = RGB(0xE0, 0xE0, 0xE0);
const COLORREF kOverlayDot = RGB(0xD8, 0xD8, 0xD8);
const COLORREF kAccentColor = RGB(0x4F, 0x8C, 0xFF);
const COLORREF kTextColor = RGB(0xE8, 0xE8, 0xE8);
const COLORREF kBarTrack = RGB(0x3A, 0x3A, 0x3A);
const COLORREF kDownloadBg = RGB(0x2A, 0x2A, 0x2A);

void PostString(UINT msg, const std::wstring& s) {
    auto* copy = new std::wstring(s);
    PostMessageW(MainWindow::Instance().Hwnd(), msg, 0, reinterpret_cast<LPARAM>(copy));
}

// UTF-8 <-> UTF-16 conversion for WebView2 messages (which arrive as UTF-16
// JSON, while the shared JSON parser works on UTF-8).
std::string WideToUtf8(const std::wstring& w) {
    if (w.empty()) return {};
    int size = WideCharToMultiByte(CP_UTF8, 0, w.c_str(), -1, nullptr, 0, nullptr, nullptr);
    if (size <= 0) return {};
    std::string s(static_cast<size_t>(size) - 1, '\0');
    WideCharToMultiByte(CP_UTF8, 0, w.c_str(), -1, s.data(), size, nullptr, nullptr);
    return s;
}

std::wstring Utf8ToWide(const std::string& s) {
    if (s.empty()) return {};
    int size = MultiByteToWideChar(CP_UTF8, 0, s.c_str(), -1, nullptr, 0);
    if (size <= 0) return {};
    std::wstring w(static_cast<size_t>(size) - 1, L'\0');
    MultiByteToWideChar(CP_UTF8, 0, s.c_str(), -1, w.data(), size);
    return w;
}

// Shows a Save As dialog (mirrors the macOS NSSavePanel flow) with `suggested`
// as the default filename and the Downloads folder as the starting location.
// Returns the chosen full path, or an empty string if the user cancelled.
// Must run on the UI thread.
std::wstring ShowSaveDialog(HWND owner, const std::wstring& suggested) {
    ComPtr<IFileSaveDialog> dialog;
    if (FAILED(CoCreateInstance(CLSID_FileSaveDialog, nullptr, CLSCTX_INPROC_SERVER,
                                IID_PPV_ARGS(&dialog)))) {
        return {};
    }

    // Default folder: the user's Downloads folder.
    PWSTR downloadsPath = nullptr;
    if (SUCCEEDED(SHGetKnownFolderPath(FOLDERID_Downloads, KF_FLAG_DEFAULT, nullptr, &downloadsPath)) &&
        downloadsPath) {
        ComPtr<IShellItem> folder;
        if (SUCCEEDED(SHCreateItemFromParsingName(downloadsPath, nullptr, IID_PPV_ARGS(&folder)))) {
            dialog->SetFolder(folder.Get());
        }
        CoTaskMemFree(downloadsPath);
    }

    dialog->SetTitle(L"Save As");
    dialog->SetFileName(suggested.empty() ? L"download" : suggested.c_str());
    // Defaults include the overwrite confirmation prompt.

    if (FAILED(dialog->Show(owner))) return {}; // cancelled or failed

    ComPtr<IShellItem> result;
    if (FAILED(dialog->GetResult(&result))) return {};
    PWSTR path = nullptr;
    if (FAILED(result->GetDisplayName(SIGDN_FILESYSPATH, &path)) || !path) return {};
    std::wstring chosen(path);
    CoTaskMemFree(path);
    return chosen;
}

// One native (WinHTTP) page download, started from a worker thread.
struct NativeDownloadJob {
    std::wstring url;
    std::wstring partPath;    // temp file while downloading
    std::wstring targetPath;  // final path chosen in the Save As dialog
    std::wstring filename;    // display name for the progress bar
};

// True when `uri` points at the local dsh server — the only content the webview
// is meant to host. Everything else belongs to the system default browser.
bool IsAppUrl(const std::wstring& uri) {
    std::wstring appUrl = ServerManager::Url(); // e.g. http://127.0.0.1:3080/
    // Strip the trailing slash so a bare "http://127.0.0.1:3080" also matches.
    if (!appUrl.empty() && appUrl.back() == L'/') appUrl.pop_back();
    if (uri.size() < appUrl.size() ||
        _wcsnicmp(uri.c_str(), appUrl.c_str(), appUrl.size()) != 0) {
        return false;
    }
    // The remainder must be empty or start with '/', '?' or '#' — this rejects
    // lookalikes such as http://127.0.0.1:30800/... while accepting /path,
    // ?query and #fragment URLs on the app origin.
    if (uri.size() == appUrl.size()) return true;
    wchar_t next = uri[appUrl.size()];
    return next == L'/' || next == L'?' || next == L'#';
}

bool IsHttpUrl(const std::wstring& uri) {
    return (uri.size() >= 8 && _wcsnicmp(uri.c_str(), L"https://", 8) == 0) ||
           (uri.size() >= 7 && _wcsnicmp(uri.c_str(), L"http://", 7) == 0);
}

// Opens `uri` in the system default browser. Returns true when the browser
// accepted the URL (ShellExecuteW reports success as a value > 32).
bool OpenInDefaultBrowser(const std::wstring& uri) {
    if (!IsHttpUrl(uri)) return false;
    HINSTANCE result = ShellExecuteW(nullptr, L"open", uri.c_str(), nullptr, nullptr, SW_SHOWNORMAL);
    return reinterpret_cast<INT_PTR>(result) > 32;
}

// ---- HKCU\Software\DeepSeekHarness settings (theme & menu language) ----

std::wstring ReadRegStr(const wchar_t* name) {
    HKEY key = nullptr;
    std::wstring value;
    if (RegOpenKeyExW(HKEY_CURRENT_USER, L"Software\\DeepSeekHarness", 0, KEY_READ, &key) == ERROR_SUCCESS) {
        DWORD size = 0;
        if (RegQueryValueExW(key, name, nullptr, nullptr, nullptr, &size) == ERROR_SUCCESS && size > 0) {
            value.resize(size / sizeof(wchar_t));
            DWORD written = size;
            if (RegQueryValueExW(key, name, nullptr, nullptr,
                                 reinterpret_cast<LPBYTE>(value.data()), &written) != ERROR_SUCCESS) {
                value.clear();
            }
            while (!value.empty() && value.back() == L'\0') value.pop_back();
        }
        RegCloseKey(key);
    }
    return value;
}

void WriteRegStr(const wchar_t* name, const std::wstring& value) {
    HKEY key = nullptr;
    if (RegCreateKeyExW(HKEY_CURRENT_USER, L"Software\\DeepSeekHarness", 0, nullptr, 0,
                        KEY_WRITE, nullptr, &key, nullptr) == ERROR_SUCCESS) {
        RegSetValueExW(key, name, 0, REG_SZ, reinterpret_cast<const BYTE*>(value.c_str()),
                       static_cast<DWORD>((value.size() + 1) * sizeof(wchar_t)));
        RegCloseKey(key);
    }
}

} // namespace

void PostOverlayStatus(const std::wstring& text) { PostString(kWM_OverlayStatus, text); }
void PostOverlayProgress(int percent) { PostMessageW(MainWindow::Instance().Hwnd(), kWM_OverlayProgress, percent == -1 ? 0xFFFFFFFF : static_cast<WPARAM>(percent), 0); }
void PostDownloadStatus(long long received, long long total, const std::wstring& filename) {
    auto* info = new DownloadStatusInfo{ received, total, filename };
    PostMessageW(MainWindow::Instance().Hwnd(), kWM_DownloadStatus, 0, reinterpret_cast<LPARAM>(info));
}
void PostShowDownloadBar() { PostMessageW(MainWindow::Instance().Hwnd(), kWM_ShowDownloadBar, 0, 0); }
void PostHideDownloadBar() { PostMessageW(MainWindow::Instance().Hwnd(), kWM_HideDownloadBar, 0, 0); }
void PostDownloadFailed(const std::wstring& message) { PostString(kWM_DownloadFailed, message); }
void PostServerReady() { PostMessageW(MainWindow::Instance().Hwnd(), kWM_ServerReady, 0, 0); }
void PostServerFailed() { PostMessageW(MainWindow::Instance().Hwnd(), kWM_ServerFailed, 0, 0); }
void PostUpdateAvailable(const std::wstring& version) { PostString(kWM_UpdateAvailable, version); }
void PostUpdateFinished(bool ok) { PostMessageW(MainWindow::Instance().Hwnd(), kWM_UpdateFinished, ok ? 1 : 0, 0); }

MainWindow& MainWindow::Instance() {
    static MainWindow instance;
    return instance;
}

LRESULT CALLBACK MainWindow::StaticWndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    auto& inst = Instance();
    inst.hwnd_ = hwnd; // valid during WM_NCCREATE (CreateWindowExW hasn't returned yet)
    return inst.WndProc(msg, wParam, lParam);
}

namespace {

// Offscreen-draws a WM_PAINT to eliminate flicker from frequent progress
// updates. Usage: draw onto `mem`, then call Commit().
struct DoubleBuffer {
    HWND hwnd = nullptr;
    PAINTSTRUCT ps{};
    HDC dc = nullptr;
    HDC mem = nullptr;
    HBITMAP bmp = nullptr;
    HGDIOBJ oldBmp = nullptr;
    int w = 0, h = 0;

    bool Begin(HWND hw) {
        hwnd = hw;
        dc = BeginPaint(hwnd, &ps);
        if (!dc) return false;
        RECT rc;
        GetClientRect(hwnd, &rc);
        w = rc.right;
        h = rc.bottom;
        mem = CreateCompatibleDC(dc);
        bmp = CreateCompatibleBitmap(dc, w, h);
        oldBmp = SelectObject(mem, bmp);
        return true;
    }

    void Commit() {
        if (mem) {
            BitBlt(dc, 0, 0, w, h, mem, 0, 0, SRCCOPY);
            SelectObject(mem, oldBmp);
            DeleteObject(bmp);
            DeleteDC(mem);
        }
        EndPaint(hwnd, &ps);
    }
};

LRESULT CALLBACK OverlayWndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    switch (msg) {
        case WM_ERASEBKGND: return 1;
        case WM_PAINT: {
            DoubleBuffer db;
            if (!db.Begin(hwnd)) return 0;
            HDC dc = db.mem;
            auto& inst = MainWindow::Instance();
            RECT rc;
            GetClientRect(hwnd, &rc);
            COLORREF bgColor = inst.DarkMode() ? kOverlayBgDark : kOverlayBg;
            COLORREF textColor = inst.DarkMode() ? kOverlayTextDark : kOverlayText;
            HBRUSH bg = CreateSolidBrush(bgColor);
            FillRect(dc, &rc, bg);
            DeleteObject(bg);

            HGDIOBJ oldFont = SelectObject(dc, GetStockObject(DEFAULT_GUI_FONT));
            SetBkMode(dc, TRANSPARENT);
            SetTextColor(dc, textColor);

            // Spinner: rotating ring of dots.
            int cx = rc.right / 2;
            int cy = (int)(rc.bottom * 0.35);
            const int kRadius = 20;
            const int kDotRadius = 4;
            for (int i = 0; i < 8; i++) {
                double angle = inst.SpinnerFrame() * M_PI / 4.0 + i * 2 * M_PI / 8.0;
                int x = cx + (int)(kRadius * cos(angle));
                int y = cy + (int)(kRadius * sin(angle));
                bool active = (inst.SpinnerFrame() % 8) == i;
                HBRUSH dot = CreateSolidBrush(active ? kAccentColor : kOverlayDot);
                HBRUSH old = (HBRUSH)SelectObject(dc, dot);
                Ellipse(dc, x - kDotRadius, y - kDotRadius, x + kDotRadius, y + kDotRadius);
                SelectObject(dc, old);
                DeleteObject(dot);
            }

            // Status text.
            RECT textRc = rc;
            textRc.top = cy + kRadius + 12;
            DrawTextW(dc, inst.OverlayText().c_str(), -1, &textRc, DT_CENTER | DT_NOPREFIX);

            // Progress bar (indeterminate when -1).
            if (inst.OverlayPercent() != -1) {
                const int kBarW = 320;
                const int kBarH = 8;
                RECT bar{ cx - kBarW / 2, (int)(rc.bottom * 0.55), cx + kBarW / 2, (int)(rc.bottom * 0.55) + kBarH };
                HBRUSH track = CreateSolidBrush(kOverlayTrack);
                FillRect(dc, &bar, track);
                DeleteObject(track);
                int fill = (int)((bar.right - bar.left) * inst.OverlayPercent() / 100.0);
                if (fill > 0) {
                    RECT fillRc = { bar.left, bar.top, bar.left + fill, bar.bottom };
                    HBRUSH accent = CreateSolidBrush(kAccentColor);
                    FillRect(dc, &fillRc, accent);
                    DeleteObject(accent);
                }
            }

            SelectObject(dc, oldFont);
            db.Commit();
            return 0;
        }
    }
    return DefWindowProcW(hwnd, msg, wParam, lParam);
}

LRESULT CALLBACK DownloadWndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    switch (msg) {
        case WM_ERASEBKGND: return 1;
        case WM_PAINT: {
            DoubleBuffer db;
            if (!db.Begin(hwnd)) return 0;
            HDC dc = db.mem;
            auto& inst = MainWindow::Instance();
            RECT rc;
            GetClientRect(hwnd, &rc);
            HBRUSH bg = CreateSolidBrush(kDownloadBg);
            FillRect(dc, &rc, bg);
            DeleteObject(bg);

            HGDIOBJ oldFont = SelectObject(dc, GetStockObject(DEFAULT_GUI_FONT));
            SetBkMode(dc, TRANSPARENT);
            SetTextColor(dc, kTextColor);

            RECT textRc = { 16, 6, rc.right - 16, 22 };
            DrawTextW(dc, inst.DownloadFilename().c_str(), -1, &textRc, DT_LEFT | DT_NOPREFIX | DT_END_ELLIPSIS);

            const int kBarH = 10;
            RECT bar{ 16, 28, rc.right - 16, 28 + kBarH };
            HBRUSH track = CreateSolidBrush(kBarTrack);
            FillRect(dc, &bar, track);
            DeleteObject(track);
            long long total = inst.DownloadTotal();
            int percent = -1;
            if (total > 0) {
                percent = (int)(inst.DownloadReceived() * 100 / total);
                if (percent > 100) percent = 100;
            }
            int fill = percent >= 0 ? (int)((bar.right - bar.left) * percent / 100.0) : 0;
            if (fill > 0) {
                RECT fillRc = { bar.left, bar.top, bar.left + fill, bar.bottom };
                HBRUSH accent = CreateSolidBrush(kAccentColor);
                FillRect(dc, &fillRc, accent);
                DeleteObject(accent);
            }
            SelectObject(dc, oldFont);
            db.Commit();
            return 0;
        }
    }
    return DefWindowProcW(hwnd, msg, wParam, lParam);
}

} // namespace

bool MainWindow::Create(HINSTANCE instance, const std::wstring& title) {
    WNDCLASSEXW wc{};
    wc.cbSize = sizeof(wc);
    wc.lpfnWndProc = StaticWndProc;
    wc.hInstance = instance;
    wc.hCursor = LoadCursorW(nullptr, reinterpret_cast<LPCWSTR>(IDC_ARROW));
    wc.hIcon = LoadIconW(instance, MAKEINTRESOURCEW(IDI_APP_ICON));
    wc.hIconSm = LoadIconW(instance, MAKEINTRESOURCEW(IDI_APP_ICON));
    wc.lpszClassName = L"DSHWebViewMainWindow";
    RegisterClassExW(&wc);

    WNDCLASSEXW overlayWc{};
    overlayWc.cbSize = sizeof(overlayWc);
    overlayWc.lpfnWndProc = OverlayWndProc;
    overlayWc.hInstance = instance;
    overlayWc.lpszClassName = L"DSHWebViewOverlay";
    RegisterClassExW(&overlayWc);

    WNDCLASSEXW downloadWc{};
    downloadWc.cbSize = sizeof(downloadWc);
    downloadWc.lpfnWndProc = DownloadWndProc;
    downloadWc.hInstance = instance;
    downloadWc.lpszClassName = L"DSHWebViewDownloadBar";
    RegisterClassExW(&downloadWc);

    // Restore persisted theme/language, then build the menu bar (its labels
    // follow the effective language). RebuildMenu() stores the handle in
    // menu_; it is passed to CreateWindowExW so the window owns it.
    LoadSettings();
    RebuildMenu();

    hwnd_ = CreateWindowExW(0, L"DSHWebViewMainWindow", title.c_str(), WS_OVERLAPPEDWINDOW,
                            CW_USEDEFAULT, CW_USEDEFAULT, 1280, 800, nullptr, menu_, instance, nullptr);
    if (hwnd_) ApplyTheme();
    return hwnd_ != nullptr;
}

void MainWindow::Show() {
    ShowWindow(hwnd_, SW_SHOW);
    UpdateWindow(hwnd_);
}

void MainWindow::Run() {
    MSG msg{};
    while (GetMessageW(&msg, nullptr, 0, 0) > 0) {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }
}

void MainWindow::Close() { PostMessageW(hwnd_, WM_CLOSE, 0, 0); }

// ---- Theme & language ----

bool MainWindow::IsChinese() const {
    if (lang_ != Lang::System) return lang_ == Lang::Zh;
    return PRIMARYLANGID(GetUserDefaultUILanguage()) == LANG_CHINESE;
}

void MainWindow::LoadSettings() {
    std::wstring theme = ReadRegStr(L"Theme");
    if (theme == L"light") theme_ = Theme::Light;
    else if (theme == L"dark") theme_ = Theme::Dark;
    else theme_ = Theme::System;

    std::wstring lang = ReadRegStr(L"Language");
    if (lang == L"zh") lang_ = Lang::Zh;
    else if (lang == L"en") lang_ = Lang::En;
    else lang_ = Lang::System;

    std::wstring relay = ReadRegStr(L"Relay");
    if (!relay.empty()) mobileRelayUrl_ = relay;
}

void MainWindow::SaveSettings() {
    WriteRegStr(L"Theme", theme_ == Theme::Light ? L"light" : theme_ == Theme::Dark ? L"dark" : L"system");
    WriteRegStr(L"Language", lang_ == Lang::Zh ? L"zh" : lang_ == Lang::En ? L"en" : L"system");
    WriteRegStr(L"Relay", mobileRelayUrl_);
}

// Recreate the menu bar with the current language and checked radio states.
// The old menu handle (detached by SetMenu) is destroyed here; the window
// owns whichever menu is currently attached.
void MainWindow::RebuildMenu() {
    bool zh = IsChinese();
    HMENU menu = CreateMenu();

    // Theme popup: 跟随系统 / 明亮 / 暗黑.
    HMENU themeMenu = CreatePopupMenu();
    AppendMenuW(themeMenu, MF_STRING | (theme_ == Theme::System ? MF_CHECKED : 0),
                kIDM_ThemeSystem, zh ? L"跟随系统" : L"Follow System");
    AppendMenuW(themeMenu, MF_STRING | (theme_ == Theme::Light ? MF_CHECKED : 0),
                kIDM_ThemeLight, zh ? L"明亮" : L"Light");
    AppendMenuW(themeMenu, MF_STRING | (theme_ == Theme::Dark ? MF_CHECKED : 0),
                kIDM_ThemeDark, zh ? L"暗黑" : L"Dark");
    AppendMenuW(menu, MF_POPUP, reinterpret_cast<UINT_PTR>(themeMenu), zh ? L"主题" : L"Theme");

    // Language popup: follow system (labeled in the current menu language)
    // plus each language under its native name. Checked state mirrors the
    // explicit preference so "follow system" stays restorable.
    HMENU langMenu = CreatePopupMenu();
    AppendMenuW(langMenu, MF_STRING | (lang_ == Lang::System ? MF_CHECKED : 0),
                kIDM_LangSystem, zh ? L"跟随系统" : L"Follow System");
    AppendMenuW(langMenu, MF_STRING | (lang_ == Lang::Zh ? MF_CHECKED : 0),
                kIDM_LangZh, L"简体中文");
    AppendMenuW(langMenu, MF_STRING | (lang_ == Lang::En ? MF_CHECKED : 0),
                kIDM_LangEn, L"English");
    AppendMenuW(menu, MF_POPUP, reinterpret_cast<UINT_PTR>(langMenu), zh ? L"语言" : L"Language");

    // Plugins Market.
    AppendMenuW(menu, MF_STRING, kIDM_PluginsMarket, zh ? L"插件市场" : L"Plugins Market");

    // Remote connect.
    AppendMenuW(menu, MF_STRING, kIDM_MobileRemote, zh ? L"远程连接…" : L"Remote Connect…");

    // Settings.
    AppendMenuW(menu, MF_STRING, kIDM_Settings, zh ? L"设置…" : L"Settings…");

    // About.
    AppendMenuW(menu, MF_STRING, kIDM_About, zh ? L"关于…" : L"About…");

    // Full screen toggle (checkable).
    AppendMenuW(menu, MF_STRING | (fullScreen_ ? MF_CHECKED : 0),
                kIDM_FullScreen, zh ? L"全屏" : L"Full Screen");

    HMENU old = menu_;
    menu_ = menu;
    if (hwnd_) {
        SetMenu(hwnd_, menu_);
        DrawMenuBar(hwnd_);
    }
    if (old) DestroyMenu(old);
}

void MainWindow::SetTheme(Theme theme) {
    if (theme_ == theme) return;
    theme_ = theme;
    SaveSettings();
    ApplyTheme();
    RebuildMenu(); // refresh the checked radio state
}

void MainWindow::SetLang(Lang lang) {
    if (lang_ == lang) return;
    lang_ = lang;
    SaveSettings();
    RebuildMenu(); // relabel the whole menu bar
}

void MainWindow::ApplyTheme() {
    if (hwnd_) {
        // Dark title bar / frame (best-effort; Windows 10 1809+).
        BOOL dark = theme_ == Theme::Dark;
        DwmSetWindowAttribute(hwnd_, DWMWA_USE_IMMERSIVE_DARK_MODE, &dark, sizeof(dark));
        if (overlayHwnd_) InvalidateRect(overlayHwnd_, nullptr, FALSE);
    }
    ApplyWebViewTheme();
}

void MainWindow::ApplyWebViewTheme() {
    if (!g_core) return;

    // prefers-color-scheme for the web content (WebView2 SDK 1.0.1518+):
    // the profile owns the preferred color scheme.
    ComPtr<ICoreWebView2_13> core13;
    if (SUCCEEDED(g_core.As(&core13))) {
        ComPtr<ICoreWebView2Profile> profile;
        if (SUCCEEDED(core13->get_Profile(&profile))) {
            COREWEBVIEW2_PREFERRED_COLOR_SCHEME scheme = COREWEBVIEW2_PREFERRED_COLOR_SCHEME_AUTO;
            if (theme_ == Theme::Light) scheme = COREWEBVIEW2_PREFERRED_COLOR_SCHEME_LIGHT;
            else if (theme_ == Theme::Dark) scheme = COREWEBVIEW2_PREFERRED_COLOR_SCHEME_DARK;
            profile->put_PreferredColorScheme(scheme);
        }
    }

    // Blank background (avoids a white flash between navigations).
    ComPtr<ICoreWebView2Controller2> controller2;
    if (SUCCEEDED(g_controller.As(&controller2))) {
        COREWEBVIEW2_COLOR bg{};
        bg.A = 255;
        if (theme_ == Theme::Dark) {
            bg.R = 0x20; bg.G = 0x20; bg.B = 0x20;
        } else {
            bg.R = 0xFF; bg.G = 0xFF; bg.B = 0xFF;
        }
        controller2->put_DefaultBackgroundColor(bg);
    }
}

// Toggle between the normal framed window and a borderless full-screen window
// covering the monitor. The saved placement/style restore the original state.
void MainWindow::ToggleFullScreen() {
    if (!hwnd_) return;
    if (fullScreen_) {
        SetWindowLongPtrW(hwnd_, GWL_STYLE, savedStyle_);
        SetWindowPlacement(hwnd_, &savedPlacement_);
        SetWindowPos(hwnd_, nullptr, 0, 0, 0, 0,
                     SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_FRAMECHANGED);
        fullScreen_ = false;
    } else {
        savedPlacement_.length = sizeof(WINDOWPLACEMENT);
        GetWindowPlacement(hwnd_, &savedPlacement_);
        savedStyle_ = GetWindowLongPtrW(hwnd_, GWL_STYLE);
        MONITORINFO mi{ sizeof(mi) };
        HMONITOR mon = MonitorFromWindow(hwnd_, MONITOR_DEFAULTTOPRIMARY);
        if (mon && GetMonitorInfoW(mon, &mi)) {
            SetWindowLongPtrW(hwnd_, GWL_STYLE, savedStyle_ & ~(WS_CAPTION | WS_THICKFRAME));
            SetWindowPos(hwnd_, HWND_TOP, mi.rcMonitor.left, mi.rcMonitor.top,
                         mi.rcMonitor.right - mi.rcMonitor.left,
                         mi.rcMonitor.bottom - mi.rcMonitor.top,
                         SWP_FRAMECHANGED | SWP_SHOWWINDOW);
            fullScreen_ = true;
        }
    }
    // Keep the menu item's checkmark in sync.
    if (menu_) {
        CheckMenuItem(menu_, kIDM_FullScreen, fullScreen_ ? MF_CHECKED : MF_UNCHECKED);
    }
}

void MainWindow::OnCreate() {
    overlayHwnd_ = CreateWindowExW(0, L"DSHWebViewOverlay", L"", WS_CHILD | WS_VISIBLE,
                                   0, 0, 0, 0, hwnd_, nullptr, GetModuleHandleW(nullptr), nullptr);
    downloadHwnd_ = CreateWindowExW(0, L"DSHWebViewDownloadBar", L"", WS_CHILD,
                                    0, 0, 0, 0, hwnd_, nullptr, GetModuleHandleW(nullptr), nullptr);
    SetOverlayText(L"Preparing runtime...");
    SetTimer(hwnd_, kSpinnerTimer, 120, nullptr);
    InitWebView2();
    StartServerThread();
}

void MainWindow::OnSize() {
    LayoutChildWindows();
}

void MainWindow::OnDestroy() {
    KillTimer(hwnd_, kSpinnerTimer);
    ServerManager::Stop();
    if (g_controller) g_controller->Close();
    PostQuitMessage(0);
}

void MainWindow::OnTimer(WPARAM wParam) {
    spinnerFrame_++;
    if (overlayHwnd_ && IsWindowVisible(overlayHwnd_)) {
        InvalidateRect(overlayHwnd_, nullptr, FALSE);
    }
    if (wParam == kRegisterTimerId && !registered_) {
        // Relay unreachable: stop the bridge and tell the user.
        KillTimer(hwnd_, kRegisterTimerId);
        registerTimerId_ = 0;
        StopBridge();
        bool zh = IsChinese();
        MessageBoxW(hwnd_, zh ? L"中继服务器不可用。请检查「设置…」中的中继地址后重试。"
                              : L"Relay server unreachable. Check the relay address in Settings… and try again.",
                    zh ? L"远程连接" : L"Remote Connect", MB_OK | MB_ICONERROR);
    }
}

void MainWindow::LayoutChildWindows() {
    RECT rc;
    GetClientRect(hwnd_, &rc);
    int barHeight = downloadBarVisible_ ? kDownloadBarHeight : 0;
    int fullBottom = rc.bottom;

    if (overlayHwnd_) SetWindowPos(overlayHwnd_, nullptr, 0, 0, rc.right, rc.bottom, SWP_NOZORDER);
    if (downloadHwnd_ && downloadBarVisible_) {
        SetWindowPos(downloadHwnd_, HWND_TOP, 0, fullBottom - barHeight, rc.right, barHeight, SWP_SHOWWINDOW);
    } else if (downloadHwnd_) {
        ShowWindow(downloadHwnd_, SW_HIDE);
    }
    if (downloadHwnd_ && downloadBarVisible_) InvalidateRect(downloadHwnd_, nullptr, FALSE);

    if (g_controller) {
        RECT webviewRc{ 0, 0, rc.right, fullBottom - barHeight };
        g_controller->put_Bounds(webviewRc);
    }
    if (overlayHwnd_) {
        SetWindowPos(overlayHwnd_, HWND_TOP, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
        InvalidateRect(overlayHwnd_, nullptr, FALSE);
    }
}

void MainWindow::ShowOverlay() {
    if (overlayHwnd_) {
        ShowWindow(overlayHwnd_, SW_SHOW);
        SetWindowPos(overlayHwnd_, HWND_TOP, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
    }
}

void MainWindow::SetOverlayText(const std::wstring& text) {
    overlayText_ = text;
    if (overlayHwnd_) InvalidateRect(overlayHwnd_, nullptr, FALSE);
}

void MainWindow::SetOverlayProgress(int percent) {
    overlayPercent_ = percent;
    if (overlayHwnd_) InvalidateRect(overlayHwnd_, nullptr, FALSE);
}

void MainWindow::ShowDownloadBar() {
    downloadBarVisible_ = true;
    LayoutChildWindows();
}

void MainWindow::HideDownloadBar() {
    downloadBarVisible_ = false;
    LayoutChildWindows();
}

void MainWindow::UpdateDownloadBar() {
    if (downloadHwnd_ && downloadBarVisible_) InvalidateRect(downloadHwnd_, nullptr, FALSE);
}

void MainWindow::InitWebView2() {
    auto userDataFolder = JoinPath(GetLocalAppData(), L"DeepSeekHarness\\WebView2");

    auto envHandler = Callback<ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler>(
        [this](HRESULT error, ICoreWebView2Environment* env) -> HRESULT {
            if (FAILED(error) || !env) {
                MessageBoxW(hwnd_, L"WebView2 environment failed to initialize.\n\n"
                                   L"Please ensure the Microsoft Edge WebView2 Runtime is installed.",
                            L"DSH WebView", MB_ICONERROR | MB_OK);
                Close();
                return S_OK;
            }
            g_env = env;
            auto controllerHandler = Callback<ICoreWebView2CreateCoreWebView2ControllerCompletedHandler>(
                [this](HRESULT err, ICoreWebView2Controller* controller) -> HRESULT {
                    if (FAILED(err) || !controller) {
                        MessageBoxW(hwnd_, L"WebView2 controller failed to initialize.", L"DSH WebView",
                                    MB_ICONERROR | MB_OK);
                        Close();
                        return S_OK;
                    }
                    g_controller = controller;
                    g_core = nullptr;
                    ComPtr<ICoreWebView2> base;
                    if (SUCCEEDED(controller->get_CoreWebView2(&base))) {
                        base.As(&g_core);
                    }
                    controller->put_ParentWindow(hwnd_);
                    ConfigureWebView();
                    WireEvents();
                    ApplyWebViewTheme();
                    LayoutChildWindows();
                    return S_OK;
                });
            g_env->CreateCoreWebView2Controller(hwnd_, controllerHandler.Get());
            return S_OK;
        });

    g_env = nullptr;
    HRESULT hr = CreateCoreWebView2EnvironmentWithOptions(
        nullptr, userDataFolder.c_str(), nullptr, envHandler.Get());
    if (FAILED(hr)) {
        MessageBoxW(hwnd_, L"WebView2 runtime is not available.\n\n"
                           L"Please install the Microsoft Edge WebView2 Runtime.",
                    L"DSH WebView", MB_ICONERROR | MB_OK);
        Close();
    }
}

void MainWindow::ConfigureWebView() {
    if (!g_core) return;
    ComPtr<ICoreWebView2Settings> settings;
    if (SUCCEEDED(g_core->get_Settings(&settings))) {
        settings->put_IsStatusBarEnabled(FALSE);
        settings->put_AreDefaultContextMenusEnabled(TRUE);
    }

    // Inject an <a download> interceptor (mirrors the macOS shell). WebView2
    // (Chromium) silently blocks downloads initiated programmatically without
    // user activation — e.g. the dsh Session ZIP export, which awaits a HEAD
    // pre-flight before clicking a generated <a download> — so DownloadStarting
    // never fires. Catch those clicks in-page and hand them to the host for a
    // native download with the same bottom progress bar. Clicks made within a
    // user gesture are left alone (WebView2 handles those via DownloadStarting,
    // keeping the page's cookies).
    static const wchar_t kDownloadInterceptorScript[] = LR"(
(() => {
    try {
        if (!(window.chrome && window.chrome.webview && window.chrome.webview.postMessage)) return;
        const originalClick = HTMLAnchorElement.prototype.click;
        HTMLAnchorElement.prototype.click = function () {
            const href = this.href || this.getAttribute('href');
            const download = this.download || this.getAttribute('download');
            const activation = (typeof navigator.userActivation === 'object' && navigator.userActivation)
                ? navigator.userActivation.isActive : true;
            if (download !== undefined && download !== null && download !== '' && href &&
                !activation && /^https?:/i.test(href)) {
                try {
                    window.chrome.webview.postMessage({ type: 'download', url: href, filename: download });
                    return;
                } catch (e) {}
            }
            return originalClick.call(this);
        };
    } catch (e) {}
})();
)";

    g_core->AddScriptToExecuteOnDocumentCreated(
        kDownloadInterceptorScript,
        Callback<ICoreWebView2AddScriptToExecuteOnDocumentCreatedCompletedHandler>(
            [](HRESULT /*error*/, PCWSTR /*id*/) -> HRESULT { return S_OK; }).Get());
}
void MainWindow::WireEvents() {
    if (!g_core) return;

    EventRegistrationToken navToken{};
    g_core->add_NavigationCompleted(
        Callback<ICoreWebView2NavigationCompletedEventHandler>(
            [this](ICoreWebView2* /*sender*/, ICoreWebView2NavigationCompletedEventArgs* args) -> HRESULT {
                BOOL success = FALSE;
                args->get_IsSuccess(&success);
                if (success) {
                    // Overlay hides once real content is up (avoids a white flash).
                    if (overlayHwnd_) ShowWindow(overlayHwnd_, SW_HIDE);
                }
                return S_OK;
            })
            .Get(), &navToken);

    // New-window requests (target="_blank" links, window.open) never spawn a
    // second webview window; the URL is opened in the system default browser.
    EventRegistrationToken newWindowToken{};
    g_core->add_NewWindowRequested(
        Callback<ICoreWebView2NewWindowRequestedEventHandler>(
            [](ICoreWebView2* /*sender*/, ICoreWebView2NewWindowRequestedEventArgs* args) -> HRESULT {
                LPWSTR uri = nullptr;
                if (SUCCEEDED(args->get_Uri(&uri)) && uri) {
                    std::wstring url(uri);
                    CoTaskMemFree(uri);
                    OpenInDefaultBrowser(url);
                }
                args->put_Handled(TRUE);
                return S_OK;
            })
            .Get(), &newWindowToken);

    // Navigations away from the local dsh server (external links) are handed
    // to the default browser instead of replacing the harness UI. Downloads of
    // external files go with them (the browser handles those); anything served
    // by the dsh server itself — including its downloads — is left untouched.
    EventRegistrationToken navStartingToken{};
    g_core->add_NavigationStarting(
        Callback<ICoreWebView2NavigationStartingEventHandler>(
            [](ICoreWebView2* /*sender*/, ICoreWebView2NavigationStartingEventArgs* args) -> HRESULT {
                LPWSTR uri = nullptr;
                if (FAILED(args->get_Uri(&uri))) return S_OK;
                std::wstring url(uri ? uri : L"");
                if (uri) CoTaskMemFree(uri);
                if (url.empty() || IsAppUrl(url)) return S_OK;
                // Cancel the webview navigation and let the browser take it —
                // but only when a browser is actually available to receive it.
                if (OpenInDefaultBrowser(url)) {
                    args->put_Cancel(TRUE);
                }
                return S_OK;
            })
            .Get(), &navStartingToken);

    // Downloads forwarded by the in-page interceptor (programmatic
    // <a download> clicks outside user activation, e.g. the Session ZIP
    // export). The page posts { type, url, filename } as JSON. The user picks
    // the destination in a Save As dialog (mirrors macOS), then the host
    // downloads natively.
    EventRegistrationToken webMessageToken{};
    g_core->add_WebMessageReceived(
        Callback<ICoreWebView2WebMessageReceivedEventHandler>(
            [this](ICoreWebView2* /*sender*/, ICoreWebView2WebMessageReceivedEventArgs* args) -> HRESULT {
                LPWSTR json = nullptr;
                if (FAILED(args->get_WebMessageAsJson(&json))) return S_OK;
                std::wstring wide(json ? json : L"");
                if (json) CoTaskMemFree(json);
                std::string utf8 = WideToUtf8(wide);
                std::string type, url, filename;
                if (!(JsonGetString(utf8, "type", type) && type == "download" &&
                      JsonGetString(utf8, "url", url) && !url.empty() &&
                      JsonGetString(utf8, "filename", filename))) {
                    return S_OK;
                }
                std::wstring target = ShowSaveDialog(hwnd_, Utf8ToWide(filename));
                if (!target.empty()) {
                    StartNativeDownload(Utf8ToWide(url), target);
                }
                return S_OK;
            })
            .Get(), &webMessageToken);

    EventRegistrationToken downloadToken{};
    g_core->add_DownloadStarting(
        Callback<ICoreWebView2DownloadStartingEventHandler>(
            [this](ICoreWebView2* /*sender*/, ICoreWebView2DownloadStartingEventArgs* args) -> HRESULT {
                args->put_Handled(TRUE); // suppress WebView2's default download UI; we show our own

                ComPtr<ICoreWebView2DownloadOperation> op;
                args->get_DownloadOperation(&op);
                if (!op) return S_OK;

                // Ask the user where to save (mirrors the macOS NSSavePanel).
                // Hold the download open with a deferral while the dialog is up.
                wchar_t* defaultPath = nullptr;
                op->get_ResultFilePath(&defaultPath);
                std::wstring name = defaultPath ? BaseName(std::wstring(defaultPath)) : L"download";
                if (defaultPath) CoTaskMemFree(defaultPath);

                ComPtr<ICoreWebView2Deferral> deferral;
                args->GetDeferral(&deferral);

                std::wstring target = ShowSaveDialog(hwnd_, name);
                if (target.empty()) {
                    args->put_Cancel(TRUE); // user cancelled the dialog
                    deferral->Complete();
                    return S_OK;
                }

                args->put_ResultFilePath(target.c_str());
                deferral->Complete();

                download_.filename = BaseName(target);
                download_.received = 0;
                download_.total = -1;
                PostShowDownloadBar();

                std::wstring filename = download_.filename;
                ComPtr<ICoreWebView2DownloadOperation> capturedOp = op;
                EventRegistrationToken bytesToken{};
                op->add_BytesReceivedChanged(
                    Callback<ICoreWebView2BytesReceivedChangedEventHandler>(
                        [this, capturedOp, filename](ICoreWebView2DownloadOperation* /*sender*/, IUnknown* /*args*/) -> HRESULT {
                            long long received = 0;
                            long long total = -1;
                            capturedOp->get_BytesReceived(&received);
                            capturedOp->get_TotalBytesToReceive(&total);
                            download_.received = received;
                            download_.total = total;
                            PostDownloadStatus(received, total, filename);
                            return S_OK;
                        })
                        .Get(), &bytesToken);

                EventRegistrationToken stateToken{};
                op->add_StateChanged(
                    Callback<ICoreWebView2StateChangedEventHandler>(
                        [this, capturedOp](ICoreWebView2DownloadOperation* /*sender*/, IUnknown* /*args*/) -> HRESULT {
                            COREWEBVIEW2_DOWNLOAD_STATE state = COREWEBVIEW2_DOWNLOAD_STATE_IN_PROGRESS;
                            capturedOp->get_State(&state);
                            if (state == COREWEBVIEW2_DOWNLOAD_STATE_INTERRUPTED) {
                                PostDownloadFailed(L"Download was interrupted and could not be completed.");
                            } else if (state != COREWEBVIEW2_DOWNLOAD_STATE_IN_PROGRESS) {
                                PostHideDownloadBar();
                            }
                            return S_OK;
                        })
                        .Get(), &stateToken);
                return S_OK;
            })
            .Get(), &downloadToken);
}

DWORD WINAPI MainWindow::EnsureNodeAndStartServer(LPVOID /*param*/) {
    bool ok = NodeRuntimeManager::Provide([](NodeRuntimeManager::State state, double progress) {
        switch (state) {
            case NodeRuntimeManager::State::Checking:
                PostOverlayStatus(L"Checking Node.js...");
                break;
            case NodeRuntimeManager::State::Downloading:
                PostOverlayStatus(L"Downloading Node.js...");
                PostOverlayProgress(progress >= 0 ? (int)(progress * 100) : -1);
                break;
            case NodeRuntimeManager::State::Installing:
                PostOverlayStatus(L"Installing Node.js...");
                PostOverlayProgress(-1);
                break;
            case NodeRuntimeManager::State::Done:
            case NodeRuntimeManager::State::Failed:
                break;
        }
    });

    if (!ok) {
        PostOverlayStatus(L"Failed to set up Node.js runtime.");
        PostServerFailed();
        return 1;
    }

    PostOverlayStatus(L"Starting DeepSeek Harness server...");
    if (!ServerManager::Start()) {
        PostOverlayStatus(L"Failed to start the dsh server.");
        PostServerFailed();
        return 1;
    }

    if (!ServerManager::WaitUntilReady(15 * 60 * 1000)) {
        PostOverlayStatus(L"Timed out waiting for the dsh server.");
        PostServerFailed();
        return 1;
    }

    PostServerReady();

    HANDLE h = CreateThread(nullptr, 0, CheckForUpdate, nullptr, 0, nullptr);
    if (h) CloseHandle(h);
    return 0;
}

void MainWindow::StartServerThread() {
    HANDLE h = CreateThread(nullptr, 0, EnsureNodeAndStartServer, nullptr, 0, nullptr);
    if (h) CloseHandle(h);
}

DWORD WINAPI MainWindow::CheckForUpdate(LPVOID /*param*/) {
    std::string latest;
    if (DSHUpdateManager::LatestIfUpdateAvailable(latest)) {
        std::wstring version(latest.begin(), latest.end());
        PostUpdateAvailable(version);
    }
    return 0;
}

void MainWindow::PromptForUpdate(const std::wstring& version) {
    std::wstring prompt = L"A new version of DeepSeek Harness is available: v" + version + L"\n\nRefresh now?";
    int choice = MessageBoxW(hwnd_, prompt.c_str(), L"DSH WebView",
                             MB_YESNO | MB_ICONINFORMATION | MB_DEFBUTTON1);
    if (choice == IDYES) {
        SetOverlayText(L"Updating DeepSeek Harness...");
        SetOverlayProgress(-1);
        ShowOverlay();
        HANDLE h = CreateThread(nullptr, 0, RefreshUpdate, nullptr, 0, nullptr);
        if (h) CloseHandle(h);
    }
}

DWORD WINAPI MainWindow::RefreshUpdate(LPVOID /*param*/) {
    bool ok = DSHUpdateManager::RefreshToLatest([](DSHUpdateManager::Status /*status*/) {});
    if (!ok) {
        PostUpdateFinished(false);
        return 1;
    }

    PostOverlayStatus(L"Restarting the dsh server...");
    ServerManager::Stop();
    if (!ServerManager::Start()) {
        PostUpdateFinished(false);
        return 1;
    }
    if (!ServerManager::WaitUntilReady(10 * 60 * 1000)) {
        PostUpdateFinished(false);
        return 1;
    }
    PostUpdateFinished(true);
    return 0;
}

// Runs on the UI thread (called from the WebMessageReceived handler after the
// user picked a destination). Queues a native page download on a worker thread
// to `targetPath`, driven by the bottom progress bar.
void MainWindow::StartNativeDownload(const std::wstring& url, const std::wstring& targetPath) {
    if (targetPath.empty()) return;
    // Download to a temp file first, then move into place, so a failed
    // transfer never leaves a partial file at the destination.
    auto part = targetPath + L".part";

    auto* job = new NativeDownloadJob{ url, part, targetPath, BaseName(targetPath) };
    HANDLE h = CreateThread(nullptr, 0, RunNativeDownload, job, 0, nullptr);
    if (h) {
        CloseHandle(h);
    } else {
        delete job;
        PostDownloadFailed(L"Download failed: " + BaseName(targetPath));
    }
}

DWORD WINAPI MainWindow::RunNativeDownload(LPVOID param) {
    std::unique_ptr<NativeDownloadJob> job(static_cast<NativeDownloadJob*>(param));
    std::wstring url = job->url;
    std::wstring part = job->partPath;
    std::wstring target = job->targetPath;
    std::wstring filename = job->filename;

    PostShowDownloadBar();
    PostDownloadStatus(0, -1, filename);

    long status = 0;
    bool ok = HttpGetToFile(url, part, [filename](long long received, long long total) {
        PostDownloadStatus(received, total, filename);
    }, &status);

    if (ok && (status < 200 || status >= 300)) ok = false; // error page, not a file

    if (ok) {
        ok = MoveFileExW(part.c_str(), target.c_str(), MOVEFILE_REPLACE_EXISTING) != FALSE;
        if (!ok) {
            DeleteFileW(part.c_str());
        }
    } else {
        DeleteFileW(part.c_str());
    }

    if (ok) {
        PostHideDownloadBar();
    } else {
        PostDownloadFailed(L"Download failed: " + filename);
    }
    return 0;
}

void MainWindow::OnDownloadFailed(const std::wstring* message) {
    HideDownloadBar();
    if (message) {
        MessageBoxW(hwnd_, message->c_str(), L"DSH WebView", MB_ICONERROR | MB_OK);
        delete message;
    }
}

void MainWindow::OnOverlayStatus(const std::wstring* text) {
    if (text) {
        SetOverlayText(*text);
        delete text;
    }
}

void MainWindow::OnOverlayProgress(WPARAM encoded) {
    int percent = encoded == 0xFFFFFFFF ? -1 : static_cast<int>(encoded);
    if (percent != overlayPercent_) {
        SetOverlayProgress(percent);
    }
}

void MainWindow::OnDownloadStatus(const DownloadStatusInfo* info) {
    if (info) {
        download_.received = info->received;
        download_.total = info->total;
        download_.filename = info->filename;
        delete info;
    }
    UpdateDownloadBar();
}

void MainWindow::OnShowDownloadBar() { ShowDownloadBar(); }
void MainWindow::OnHideDownloadBar() { HideDownloadBar(); }

void MainWindow::OnServerReady() {
    if (g_core) {
        g_core->Navigate(ServerManager::Url().c_str());
    }
}

void MainWindow::OnServerFailed() {
    MessageBoxW(hwnd_, L"The DeepSeek Harness server could not be started.\n\n"
                       L"See " L"%TEMP%\\DSHWebView-dsh.log" L" for details.",
                L"DSH WebView", MB_ICONERROR | MB_OK);
    Close();
}

void MainWindow::OnUpdateAvailable(const std::wstring* version) {
    if (version) {
        PromptForUpdate(*version);
        delete version;
    }
}

void MainWindow::OnUpdateFinished(bool ok) {
    if (ok) {
        SetOverlayProgress(-1);
        OnServerReady();
    } else {
        ShowOverlay();
        SetOverlayText(L"Update failed; using the cached version.");
        OnServerReady();
    }
}

LRESULT MainWindow::WndProc(UINT msg, WPARAM wParam, LPARAM lParam) {
    switch (msg) {
        case WM_CREATE: OnCreate(); return 0;
        case WM_SIZE: OnSize(); return 0;
        case WM_TIMER: OnTimer(wParam); return 0;
        case WM_DESTROY: OnDestroy(); return 0;
        case kWM_OverlayStatus: OnOverlayStatus(reinterpret_cast<std::wstring*>(lParam)); return 0;
        case kWM_OverlayProgress: OnOverlayProgress(wParam); return 0;
        case kWM_DownloadStatus: OnDownloadStatus(reinterpret_cast<DownloadStatusInfo*>(lParam)); return 0;
        case kWM_ShowDownloadBar: OnShowDownloadBar(); return 0;
        case kWM_HideDownloadBar: OnHideDownloadBar(); return 0;
        case kWM_ServerReady: OnServerReady(); return 0;
        case kWM_ServerFailed: OnServerFailed(); return 0;
        case kWM_UpdateAvailable: OnUpdateAvailable(reinterpret_cast<std::wstring*>(lParam)); return 0;
        case kWM_UpdateFinished: OnUpdateFinished(wParam != 0); return 0;
        case kWM_DownloadFailed: OnDownloadFailed(reinterpret_cast<std::wstring*>(lParam)); return 0;
        case kWM_BridgeLine: OnBridgeLine(reinterpret_cast<std::wstring*>(lParam)); return 0;
        case WM_COMMAND:
            switch (LOWORD(wParam)) {
                case kIDM_PluginsMarket:
                    OpenInDefaultBrowser(L"https://tonytsangzen.github.io/harness-market/");
                    return 0;
                case kIDM_MobileRemote: OnMobileRemote(); return 0;
                case kIDM_Settings: OnSettings(); return 0;
                case kIDM_About: OnAbout(); return 0;
                case kIDM_ThemeSystem: SetTheme(Theme::System); return 0;
                case kIDM_ThemeLight: SetTheme(Theme::Light); return 0;
                case kIDM_ThemeDark: SetTheme(Theme::Dark); return 0;
                case kIDM_LangZh: SetLang(Lang::Zh); return 0;
                case kIDM_LangEn: SetLang(Lang::En); return 0;
                case kIDM_LangSystem: SetLang(Lang::System); return 0;
                case kIDM_FullScreen: ToggleFullScreen(); return 0;
            }
            return 0;
        case WM_GETMINMAXINFO: {
            auto* mmi = reinterpret_cast<MINMAXINFO*>(lParam);
            mmi->ptMinTrackSize.x = 640;
            mmi->ptMinTrackSize.y = 400;
            return 0;
        }
    }
    return DefWindowProcW(hwnd_, msg, wParam, lParam);
}

// MARK: - Mobile remote (relay bridge)

namespace {

// Context passed to the pairing dialog (PIN + shell device ID + QR PNG).
struct PairingCtx {
    std::wstring pin;
    std::wstring deviceId;
    std::string qrPNG;
};

// ---- In-memory dialog template builder (tiny dialogs without .rc) ----

struct TemplateItem {
    int id;
    const wchar_t* cls;
    const wchar_t* text;
    DWORD style;
    short x, y, cx, cy;
};

void PadDword(std::vector<BYTE>& v) {
    while (v.size() % 4) v.push_back(0);
}

void AddWord(std::vector<BYTE>& v, WORD w) {
    v.push_back(static_cast<BYTE>(w & 0xFF));
    v.push_back(static_cast<BYTE>((w >> 8) & 0xFF));
}

void AddDword(std::vector<BYTE>& v, DWORD d) {
    PadDword(v);
    for (int i = 0; i < 4; ++i) v.push_back(static_cast<BYTE>((d >> (8 * i)) & 0xFF));
}

void AddString(std::vector<BYTE>& v, const wchar_t* s) {
    if (!s) s = L"";
    PadDword(v);
    while (*s) AddWord(v, static_cast<WORD>(*s++));
    AddWord(v, 0);
}

HGLOBAL BuildDialogTemplate(const wchar_t* caption, short cx, short cy,
                            const std::vector<TemplateItem>& items) {
    std::vector<BYTE> v;
    AddDword(v, 0x00010000); // dlgVer + signature
    AddDword(v, 0);          // helpID + exStyle
    AddDword(v, DS_SETFONT | DS_MODALFRAME | WS_POPUP | WS_CAPTION | WS_SYSMENU);
    AddWord(v, static_cast<WORD>(items.size()));
    AddWord(v, 0); AddWord(v, 0); // x, y (centered by dialog manager)
    AddWord(v, cx); AddWord(v, cy);
    AddString(v, caption);
    AddString(v, L"MS Shell Dlg");
    AddWord(v, 9); // font size
    for (const auto& it : items) {
        AddDword(v, it.style);
        AddDword(v, 0); // exStyle
        AddWord(v, static_cast<WORD>(it.x));
        AddWord(v, static_cast<WORD>(it.y));
        AddWord(v, static_cast<WORD>(it.cx));
        AddWord(v, static_cast<WORD>(it.cy));
        AddWord(v, static_cast<WORD>(it.id));
        AddString(v, it.cls);
        AddString(v, it.text);
        AddWord(v, 0); // creation data
    }
    HGLOBAL hg = GlobalAlloc(GMEM_MOVEABLE, v.size());
    if (!hg) return nullptr;
    void* p = GlobalLock(hg);
    if (p) {
        memcpy(p, v.data(), v.size());
        GlobalUnlock(hg);
    }
    return hg;
}

// ---- GDI+ (used to render the QR PNG) ----

ULONG_PTR g_gdiplusToken = 0;

bool EnsureGdiPlus() {
    static bool ok = [] {
        Gdiplus::GdiplusStartupInput input;
        return Gdiplus::GdiplusStartup(&g_gdiplusToken, &input, nullptr) == Gdiplus::Ok;
    }();
    return ok;
}

HBITMAP HBitmapFromPng(const BYTE* png, size_t len) {
    if (!EnsureGdiPlus()) return nullptr;
    HGLOBAL hg = GlobalAlloc(GMEM_MOVEABLE, len);
    if (!hg) return nullptr;
    void* p = GlobalLock(hg);
    if (!p) { GlobalFree(hg); return nullptr; }
    memcpy(p, png, len);
    GlobalUnlock(hg);
    IStream* stream = nullptr;
    if (FAILED(CreateStreamOnHGlobal(hg, TRUE, &stream))) { GlobalFree(hg); return nullptr; }
    Gdiplus::Bitmap bmp(stream);
    stream->Release();
    HBITMAP hbmp = nullptr;
    bmp.GetHBITMAP(Gdiplus::Color(255, 255, 255), &hbmp);
    return hbmp;
}

// ---- Device ID + pairing QR (shell-generated) ----

int GetEncoderClsid(const wchar_t* mimeType, CLSID* clsid) {
    UINT num = 0, size = 0;
    Gdiplus::GetImageEncodersSize(&num, &size);
    if (size == 0) return -1;
    std::vector<BYTE> buf(size);
    Gdiplus::ImageCodecInfo* enc = reinterpret_cast<Gdiplus::ImageCodecInfo*>(buf.data());
    Gdiplus::GetImageEncoders(num, size, enc);
    for (UINT i = 0; i < num; i++) {
        if (wcscmp(enc[i].MimeType, mimeType) == 0) {
            *clsid = enc[i].Clsid;
            return i;
        }
    }
    return -1;
}

std::string SaveBitmapPng(Gdiplus::Bitmap* bmp) {
    CLSID clsid;
    if (GetEncoderClsid(L"image/png", &clsid) < 0) return "";
    IStream* stream = nullptr;
    if (FAILED(CreateStreamOnHGlobal(nullptr, TRUE, &stream))) return "";
    Gdiplus::Status st = bmp->Save(stream, &clsid, nullptr);
    if (st != Gdiplus::Ok) { stream->Release(); return ""; }
    HGLOBAL hg = nullptr;
    GetHGlobalFromStream(stream, &hg);
    SIZE_T len = GlobalSize(hg);
    const BYTE* p = static_cast<const BYTE*>(GlobalLock(hg));
    std::string out(reinterpret_cast<const char*>(p), len);
    GlobalUnlock(hg);
    stream->Release();
    return out;
}

// First non-loopback IPv4 address in a private range (LAN direct connect),
// mirroring the macOS shell so the phone can prefer a direct LAN connection.
std::string LocalLANAddress() {
    std::string result;
    ULONG size = 0;
    GetAdaptersAddresses(AF_INET, GAA_FLAG_SKIP_ANYCAST | GAA_FLAG_SKIP_MULTICAST |
                                       GAA_FLAG_SKIP_DNS_SERVER,
                         nullptr, nullptr, &size);
    if (size == 0) return "";
    std::vector<BYTE> buf(size);
    PIP_ADAPTER_ADDRESSES addrs = reinterpret_cast<PIP_ADAPTER_ADDRESSES>(buf.data());
    if (GetAdaptersAddresses(AF_INET, GAA_FLAG_SKIP_ANYCAST | GAA_FLAG_SKIP_MULTICAST |
                                          GAA_FLAG_SKIP_DNS_SERVER,
                             nullptr, addrs, &size) != NO_ERROR) {
        return "";
    }
    for (PIP_ADAPTER_ADDRESSES a = addrs; a; a = a->Next) {
        if (a->OperStatus != IfOperStatusUp) continue;
        for (PIP_ADAPTER_UNICAST_ADDRESS u = a->FirstUnicastAddress; u; u = u->Next) {
            if (u->Address.lpSockaddr->sa_family != AF_INET) continue;
            auto* sin = reinterpret_cast<sockaddr_in*>(u->Address.lpSockaddr);
            char ip[INET_ADDRSTRLEN] = {};
            inet_ntop(AF_INET, &sin->sin_addr, ip, sizeof(ip));
            std::string s = ip;
            if (s.rfind("192.168.", 0) == 0) return s; // prefer 192.168.*
            if (s.rfind("10.", 0) == 0 || s.rfind("172.", 0) == 0) {
                if (result.empty()) result = s;
            }
        }
    }
    return result;
}

// Stable pairing PIN: generated once, then kept in the registry so reconnects
// reuse the same host identity (mirrors the macOS shell's UserDefaults PIN).
std::wstring StablePairingPin() {
    HKEY key = nullptr;
    wchar_t pin[16] = {};
    DWORD psize = sizeof(pin);
    if (RegOpenKeyExW(HKEY_CURRENT_USER, L"Software\\DSHWebView", 0, KEY_READ, &key) ==
            ERROR_SUCCESS) {
        if (RegQueryValueExW(key, L"PairingPin", nullptr, nullptr,
                             reinterpret_cast<LPBYTE>(pin), &psize) == ERROR_SUCCESS &&
            wcslen(pin) == 6) {
            RegCloseKey(key);
            return pin;
        }
        RegCloseKey(key);
    }
    // Generate a fresh 6-digit PIN.
    HCRYPTPROV prov = 0;
    std::wstring npin;
    if (CryptAcquireContextW(&prov, nullptr, nullptr, PROV_RSA_FULL, CRYPT_VERIFYCONTEXT)) {
        BYTE rnd[6] = {};
        if (CryptGenRandom(prov, sizeof(rnd), rnd)) {
            for (BYTE b : rnd) npin += static_cast<wchar_t>(L'0' + (b % 10));
        }
        CryptReleaseContext(prov, 0);
    }
    if (npin.size() != 6) {
        npin = L"123456"; // last-resort fallback
    }
    if (RegCreateKeyExW(HKEY_CURRENT_USER, L"Software\\DSHWebView", 0, nullptr, 0,
                        KEY_WRITE, nullptr, &key, nullptr) == ERROR_SUCCESS) {
        RegSetValueExW(key, L"PairingPin", 0, REG_SZ,
                       reinterpret_cast<const BYTE*>(npin.c_str()),
                       static_cast<DWORD>((npin.size() + 1) * sizeof(wchar_t)));
        RegCloseKey(key);
    }
    return npin;
}

// 13-digit random device ID derived from device info (hostname + MachineGuid),
// stable across launches so reconnects reuse the same host identity.
std::string DeviceID() {
    wchar_t host[256] = {};    DWORD hlen = 256;
    GetComputerNameW(host, &hlen);
    std::string seed = WideToUtf8(host);
    HKEY key = nullptr;
    if (RegOpenKeyExW(HKEY_LOCAL_MACHINE, L"SOFTWARE\\Microsoft\\Cryptography",
                      0, KEY_READ, &key) == ERROR_SUCCESS) {
        wchar_t guid[128] = {};
        DWORD gsz = sizeof(guid);
        if (RegQueryValueExW(key, L"MachineGuid", nullptr, nullptr,
                             reinterpret_cast<LPBYTE>(guid), &gsz) == ERROR_SUCCESS) {
            seed += "|" + WideToUtf8(guid);
        }
        RegCloseKey(key);
    }
    BYTE digest[32] = {};
    HCRYPTPROV prov = 0;
    HCRYPTHASH hash = 0;
    if (CryptAcquireContextW(&prov, nullptr, nullptr, PROV_RSA_FULL, CRYPT_VERIFYCONTEXT) &&
        CryptCreateHash(prov, CALG_SHA_256, 0, 0, &hash)) {
        CryptHashData(hash, reinterpret_cast<const BYTE*>(seed.data()),
                      static_cast<DWORD>(seed.size()), 0);
        DWORD dlen = 32;
        CryptGetHashParam(hash, HP_HASHVAL, digest, &dlen, 0);
        CryptDestroyHash(hash);
        CryptReleaseContext(prov, 0);
    }
    unsigned long long value = 0;
    for (int i = 0; i < 8; i++) value = (value << 8) | digest[i];
    wchar_t buf[16] = {};
    swprintf(buf, 16, L"%013llu", value % 10000000000000ULL);
    return WideToUtf8(buf);
}

// The pairing QR content: relay host + device ID, plus the relay's own scheme
// (http for plaintext test relays, https otherwise) so the phone connects
// with a matching protocol. `lanAddress` (e.g. "192.168.1.5:13080") lets the
// phone prefer a direct LAN connection to this desktop's dsh web and only
// fall back to the cloud relay when it can't reach it.
std::string PairingQRContent(const std::wstring& relayUrl, const std::string& deviceId,
                             const std::string& lanAddress) {
    std::wstring scheme = L"https";
    std::wstring host = relayUrl;
    size_t sep = host.find(L"://");
    if (sep != std::wstring::npos) {
        scheme = host.substr(0, sep);
        host = host.substr(sep + 3);
    }
    size_t slash = host.find(L'/');
    if (slash != std::wstring::npos) host = host.substr(0, slash);
    std::string qr = "relay://" + WideToUtf8(host) + "/pair?device=" + deviceId +
                     "&scheme=" + WideToUtf8(scheme);
    if (!lanAddress.empty()) qr += "&lan=" + lanAddress;
    return qr;
}

// Renders a QR code as PNG data using the vendored qrcodegen library.
std::string GenerateQRPNG(const std::string& content) {
    if (!EnsureGdiPlus()) return "";
    uint8_t qrcode[qrcodegen_BUFFER_LEN_MAX];
    uint8_t temp[qrcodegen_BUFFER_LEN_MAX];
    if (!qrcodegen_encodeText(content.c_str(), temp, qrcode, qrcodegen_Ecc_MEDIUM,
                              qrcodegen_VERSION_MIN, qrcodegen_VERSION_MAX,
                              qrcodegen_Mask_AUTO, true)) {
        return "";
    }
    int size = qrcodegen_getSize(qrcode);
    const int scale = 10;
    int dim = size * scale;
    Gdiplus::Bitmap bmp(dim, dim, PixelFormat24bppRGB);
    Gdiplus::BitmapData bd;
    Gdiplus::Rect rc(0, 0, dim, dim);
    bmp.LockBits(&rc, Gdiplus::ImageLockModeWrite, PixelFormat24bppRGB, &bd);
    BYTE* px = static_cast<BYTE*>(bd.Scan0);
    for (int y = 0; y < size; y++) {
        for (int x = 0; x < size; x++) {
            BYTE v = qrcodegen_getModule(qrcode, x, y) ? 0 : 255;
            for (int dy = 0; dy < scale; dy++) {
                for (int dx = 0; dx < scale; dx++) {
                    BYTE* p = px + (y * scale + dy) * bd.Stride + (x * scale + dx) * 3;
                    p[0] = v; p[1] = v; p[2] = v;
                }
            }
        }
    }
    bmp.UnlockBits(&bd);
    return SaveBitmapPng(&bmp);
}

// True for localhost / 127.x / ::1 — where a plain-HTTP relay is expected
// during testing (scheme auto-completion uses this).
bool IsLoopbackHost(const std::wstring& hostOrAddr) {
    std::wstring h = hostOrAddr;
    for (auto& c : h) c = towlower(c);
    return h == L"localhost" || h == L"::1" || h.rfind(L"127.", 0) == 0;
}

} // namespace

// MARK: - Settings (mobile relay address)

INT_PTR CALLBACK MainWindow::SettingsDlgProc(HWND hDlg, UINT msg, WPARAM wParam, LPARAM lParam) {
    if (msg == WM_INITDIALOG) {
        auto* relay = reinterpret_cast<std::wstring*>(lParam);
        SetWindowLongPtrW(hDlg, DWLP_USER, lParam);
        bool zh = MainWindow::Instance().IsChinese();
        SetDlgItemTextW(hDlg, 101, zh ? L"中继地址（URL 或 IP:端口）" : L"Relay address (URL or IP:port)");
        SetDlgItemTextW(hDlg, 104, zh ? L"远程 App 通过该云端中继连接本机。保存后「远程连接」使用此地址。"
                                      : L"The remote app connects to this machine through this cloud relay. Used by Remote Connect.");
        SetDlgItemTextW(hDlg, 103, relay->c_str());
        return TRUE;
    }
    if (msg == WM_COMMAND) {
        switch (LOWORD(wParam)) {
            case IDOK: {
                auto* relay = reinterpret_cast<std::wstring*>(GetWindowLongPtrW(hDlg, DWLP_USER));
                wchar_t buf[512] = {};
                GetDlgItemTextW(hDlg, 103, buf, 512);
                std::wstring raw = buf;
                size_t b = raw.find_first_not_of(L" \t\r\n");
                size_t e = raw.find_last_not_of(L" \t\r\n");
                raw = (b == std::wstring::npos) ? L"" : raw.substr(b, e - b + 1);
                if (!raw.empty() && raw.rfind(L"http://", 0) != 0 && raw.rfind(L"https://", 0) != 0) {
                    // Loopback addresses usually run a plain-HTTP test relay.
                    raw = IsLoopbackHost(raw) ? L"http://" + raw : L"https://" + raw;
                }
                *relay = raw;
                EndDialog(hDlg, IDOK);
                return TRUE;
            }
            case IDCANCEL: EndDialog(hDlg, IDCANCEL); return TRUE;
        }
    }
    return FALSE;
}

void MainWindow::OnAbout() {
    bool zh = IsChinese();

    std::string engine = LocalVersion();
    if (engine.empty()) engine = zh ? "未安装" : "not installed";
    std::wstring node = NodeRuntimeManager::NodeVersion();
    if (node.empty()) node = zh ? L"未安装" : L"not installed";

    std::wstring text = L"DeepSeek Harness\n\n";
    text += (zh ? L"版本: " : L"Version: ") + Utf8ToWide(APP_VERSION) + L"\n";
    text += (zh ? L"引擎（dsh web）: " : L"Engine (dsh web): ") + Utf8ToWide(engine) + L"\n";
    text += L"Node.js: " + node;
    MessageBoxW(hwnd_, text.c_str(), (zh ? L"关于" : L"About"), MB_OK | MB_ICONINFORMATION);
}

void MainWindow::OnSettings() {
    std::wstring relay = mobileRelayUrl_;
    bool zh = IsChinese();
    std::vector<TemplateItem> items = {
        { 101, L"Static", nullptr, SS_LEFT | WS_CHILD | WS_VISIBLE, 14, 14, 260, 18 },
        { 103, L"Edit", L"", ES_LEFT | WS_BORDER | WS_TABSTOP | WS_CHILD | WS_VISIBLE, 14, 38, 260, 22 },
        { 104, L"Static", nullptr, SS_LEFT | WS_CHILD | WS_VISIBLE, 14, 66, 260, 52 },
        { IDOK, L"Button", L"OK", BS_PUSHBUTTON | WS_TABSTOP | WS_CHILD | WS_VISIBLE, 120, 128, 60, 24 },
        { IDCANCEL, L"Button", L"Cancel", BS_PUSHBUTTON | WS_TABSTOP | WS_CHILD | WS_VISIBLE, 190, 128, 60, 24 },
    };
    // Label and hint text are set in WM_INITDIALOG (dynamic text).
    HGLOBAL tmpl = BuildDialogTemplate(zh ? L"设置" : L"Settings", 288, 162, items);
    if (!tmpl) return;
    DialogBoxIndirectParamW(GetModuleHandleW(nullptr),
                            reinterpret_cast<LPCTSTR>(tmpl),
                            hwnd_, SettingsDlgProc,
                            reinterpret_cast<LPARAM>(&relay));
    GlobalFree(tmpl);
    if (relay != mobileRelayUrl_) {
        mobileRelayUrl_ = relay;
        SaveSettings();
    }
}

void MainWindow::OnMobileRemote() {
    if (bridgeRunning_) {
        bool zh = IsChinese();
        int r = MessageBoxW(hwnd_, zh ? L"已连接，是否断开？" : L"Connected. Disconnect?",
                            zh ? L"远程连接" : L"Remote Connect",
                            MB_YESNO | MB_ICONQUESTION);
        if (r == IDYES) StopBridge();
        return;
    }

    // Relay address comes from Settings… (mobileRelayUrl_).
    if (mobileRelayUrl_.empty()) {
        bool zh = IsChinese();
        int r = MessageBoxW(hwnd_,
                            zh ? L"尚未配置中继地址。请先在「设置…」中填写中继地址，再使用远程连接。"
                               : L"Relay address not configured. Set it in Settings… first, then use Remote Connect.",
                            zh ? L"远程连接" : L"Remote Connect",
                            MB_OKCANCEL | MB_ICONINFORMATION);
        if (r == IDOK) OnSettings();
        return;
    }

    // Shell-generated device ID + pairing QR (relay host + device ID, plus the
    // LAN address of the bridge's direct-connect proxy so the phone can prefer
    // a direct connection and fall back to the relay).
    deviceId_ = DeviceID();
    std::string lan = LocalLANAddress();
    if (!lan.empty()) lan += ":13080";
    qrPNG_ = GenerateQRPNG(PairingQRContent(mobileRelayUrl_, deviceId_, lan));
    if (qrPNG_.empty()) {
        bool zh = IsChinese();
        MessageBoxW(hwnd_, zh ? L"生成配对二维码失败。" : L"Failed to generate the pairing QR code.",
                    zh ? L"远程连接" : L"Remote Connect", MB_OK | MB_ICONERROR);
        return;
    }
    registered_ = false;

    // Registration must succeed within 12s or the relay is unreachable.
    registerTimerId_ = SetTimer(hwnd_, kRegisterTimerId, 12000, nullptr);

    StartBridge(mobileRelayUrl_, deviceId_);
}

void MainWindow::StartBridge(const std::wstring& relay, const std::string& deviceId) {
    std::wstring node = NodePath();
    if (node.empty()) {
        MessageBoxW(hwnd_, IsChinese() ? L"未找到 Node.js。" : L"Node.js not found.",
                    L"DSH WebView", MB_ICONERROR | MB_OK);
        return;
    }
    // Bridge script: $DSH_BRIDGE_DIR, or next to the executable.
    std::wstring bridge;
    if (const wchar_t* env = _wgetenv(L"DSH_BRIDGE_DIR"); env && env[0]) {
        bridge = std::wstring(env) + L"\\bridge.mjs";
    }
    if (bridge.empty() || GetFileAttributesW(bridge.c_str()) == INVALID_FILE_ATTRIBUTES) {
        wchar_t exe[MAX_PATH] = {};
        GetModuleFileNameW(nullptr, exe, MAX_PATH);
        std::wstring dir = exe;
        dir = dir.substr(0, dir.find_last_of(L"\\/"));
        bridge = dir + L"\\bridge\\bridge.mjs";
    }
    if (GetFileAttributesW(bridge.c_str()) == INVALID_FILE_ATTRIBUTES) {
        MessageBoxW(hwnd_, IsChinese() ? L"未找到远程连接桥接脚本（bridge.mjs）。"
                                       : L"Remote connect bridge script (bridge.mjs) not found.",
                    L"DSH WebView", MB_ICONERROR | MB_OK);
        return;
    }

    SECURITY_ATTRIBUTES sa{ sizeof(sa), nullptr, TRUE };
    HANDLE outRead = nullptr, outWrite = nullptr;
    if (!CreatePipe(&outRead, &outWrite, &sa, 0)) return;
    SetHandleInformation(outRead, HANDLE_FLAG_INHERIT, 0);

    std::wstring cmd = L"\"" + node + L"\" \"" + bridge + L"\" --relay " + relay +
                       L" --dsh-port " + std::to_wstring(ServerManager::Port()) +
                       L" --device-id " + Utf8ToWide(deviceId) +
                       L" --pin " + StablePairingPin();
    STARTUPINFOW si{};
    si.cb = sizeof(si);
    si.dwFlags = STARTF_USESTDHANDLES;
    si.hStdOutput = outWrite;
    si.hStdError = GetStdHandle(STD_ERROR_HANDLE);
    si.hStdInput = GetStdHandle(STD_INPUT_HANDLE);
    PROCESS_INFORMATION pi{};
    if (!CreateProcessW(node.c_str(), &cmd[0], nullptr, nullptr, TRUE,
                        CREATE_NO_WINDOW, nullptr, nullptr, &si, &pi)) {
        CloseHandle(outRead);
        CloseHandle(outWrite);
        return;
    }
    CloseHandle(outWrite);
    CloseHandle(pi.hThread);
    bridgeProc_ = pi;
    bridgeStdout_ = outRead;
    bridgeRunning_ = true;
    bridgeBuffer_.clear();
    bridgeThread_ = CreateThread(nullptr, 0, BridgeReaderThread, this, 0, nullptr);
}

void MainWindow::StopBridge() {
    bridgeRunning_ = false;
    if (bridgeProc_.hProcess) {
        TerminateProcess(bridgeProc_.hProcess, 1);
        WaitForSingleObject(bridgeProc_.hProcess, 5000);
        CloseHandle(bridgeProc_.hProcess);
        bridgeProc_ = {};
    }
    if (bridgeStdout_) { CloseHandle(bridgeStdout_); bridgeStdout_ = nullptr; }
    if (bridgeThread_) {
        WaitForSingleObject(bridgeThread_, 5000);
        CloseHandle(bridgeThread_);
        bridgeThread_ = nullptr;
    }
}

DWORD WINAPI MainWindow::BridgeReaderThread(LPVOID param) {
    auto* self = static_cast<MainWindow*>(param);
    char buf[4096];
    DWORD got = 0;
    std::string acc;
    for (;;) {
        if (!ReadFile(self->bridgeStdout_, buf, sizeof(buf), &got, nullptr) || got == 0) break;
        acc.append(buf, got);
        size_t nl;
        while ((nl = acc.find('\n')) != std::string::npos) {
            std::string line = acc.substr(0, nl);
            acc.erase(0, nl + 1);
            if (!line.empty()) PostString(kWM_BridgeLine, Utf8ToWide(line));
        }
    }
    return 0;
}

void MainWindow::OnBridgeLine(const std::wstring* line) {
    if (!line) return;
    std::string utf8 = WideToUtf8(*line);
    delete line;
    std::string event;
    if (!JsonGetString(utf8, "event", event)) return;
    if (event == "registered") {
        registered_ = true;
        if (registerTimerId_ != 0) {
            KillTimer(hwnd_, kRegisterTimerId);
            registerTimerId_ = 0;
        }
        std::string pin;
        JsonGetString(utf8, "pin", pin);
        ShowPairingDialog(Utf8ToWide(pin), Utf8ToWide(deviceId_), qrPNG_);
    }
}

INT_PTR CALLBACK MainWindow::PairingDialogProc(HWND hDlg, UINT msg, WPARAM wParam, LPARAM lParam) {
    if (msg == WM_INITDIALOG) {
        auto* ctx = reinterpret_cast<PairingCtx*>(lParam);
        SetWindowLongPtrW(hDlg, DWLP_USER, lParam);
        bool zh = MainWindow::Instance().IsChinese();
        SetDlgItemTextW(hDlg, 103, (zh ? L"PIN: " : L"PIN: ") + ctx->pin);
        SetDlgItemTextW(hDlg, 104, (zh ? L"设备码: " : L"Device ID: ") + ctx->deviceId);
        SetDlgItemTextW(hDlg, 105, zh ? L"在 Harness 远程 App 中扫描上方二维码；或手动输入设备码与 PIN。"
                                      : L"Scan the QR code in the Harness Remote app, or enter the device ID and PIN manually.");
        if (!ctx->qrPNG.empty()) {
            HBITMAP hbmp = HBitmapFromPng(reinterpret_cast<const BYTE*>(ctx->qrPNG.data()),
                                          ctx->qrPNG.size());
            if (hbmp) {
                HWND qr = GetDlgItem(hDlg, 102);
                HBITMAP old = reinterpret_cast<HBITMAP>(SendMessageW(qr, STM_SETIMAGE,
                                                                     IMAGE_BITMAP,
                                                                     reinterpret_cast<LPARAM>(hbmp)));
                if (old) DeleteObject(old);
            }
        }
        return TRUE;
    }
    if (msg == WM_COMMAND && LOWORD(wParam) == IDOK) {
        EndDialog(hDlg, IDOK);
        return TRUE;
    }
    return FALSE;
}

void MainWindow::ShowPairingDialog(const std::wstring& pin, const std::wstring& deviceId,
                                   const std::string& qrPNG) {
    bool zh = IsChinese();
    std::vector<TemplateItem> items = {
        { 102, L"Static", L"", SS_BITMAP | SS_CENTERIMAGE | WS_CHILD | WS_VISIBLE, 14, 14, 200, 200 },
        { 103, L"Static", L"", SS_CENTER | WS_CHILD | WS_VISIBLE, 14, 224, 200, 32 },
        { 104, L"Static", L"", SS_CENTER | WS_CHILD | WS_VISIBLE, 14, 258, 200, 26 },
        { 105, L"Static", L"", SS_CENTER | WS_CHILD | WS_VISIBLE, 14, 288, 200, 44 },
        { IDOK, L"Button", L"OK", BS_PUSHBUTTON | WS_TABSTOP | WS_CHILD | WS_VISIBLE, 90, 340, 60, 24 },
    };
    PairingCtx ctx{ pin, deviceId, qrPNG };
    HGLOBAL tmpl = BuildDialogTemplate(zh ? L"远程连接配对" : L"Remote Connect Pairing", 228, 372, items);
    if (!tmpl) return;
    DialogBoxIndirectParamW(GetModuleHandleW(nullptr),
                            reinterpret_cast<LPCTSTR>(tmpl),
                            hwnd_, PairingDialogProc,
                            reinterpret_cast<LPARAM>(&ctx));
    GlobalFree(tmpl);
}

} // namespace dsh
