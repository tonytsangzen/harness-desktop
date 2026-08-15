#define _USE_MATH_DEFINES
#include "main_window.h"

#include "dsh_update_manager.h"
#include "http.h"
#include "json.h"
#include "node_runtime_manager.h"
#include "resource.h"
#include "server_manager.h"
#include "settings.h"
#include "util.h"

#include <wrl/client.h>
#include <wrl/event.h>
#include <webview2.h>

#include <shlobj.h>
#include <shobjidl.h>

#include <cmath>
#include <memory>
#include <string>
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

const UINT_PTR kSpinnerTimer = 1;
const int kDownloadBarHeight = 48;

const COLORREF kOverlayBg = RGB(0xFF, 0xFF, 0xFF);
const COLORREF kOverlayText = RGB(0x20, 0x20, 0x20);
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
            HBRUSH bg = CreateSolidBrush(kOverlayBg);
            FillRect(dc, &rc, bg);
            DeleteObject(bg);

            HGDIOBJ oldFont = SelectObject(dc, GetStockObject(DEFAULT_GUI_FONT));
            SetBkMode(dc, TRANSPARENT);
            SetTextColor(dc, kOverlayText);

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

    hwnd_ = CreateWindowExW(0, L"DSHWebViewMainWindow", title.c_str(), WS_OVERLAPPEDWINDOW,
                            CW_USEDEFAULT, CW_USEDEFAULT, 1280, 800, nullptr, nullptr, instance, nullptr);
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

void MainWindow::OnTimer() {
    spinnerFrame_++;
    if (overlayHwnd_ && IsWindowVisible(overlayHwnd_)) {
        InvalidateRect(overlayHwnd_, nullptr, FALSE);
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

    EventRegistrationToken newWindowToken{};
    g_core->add_NewWindowRequested(
        Callback<ICoreWebView2NewWindowRequestedEventHandler>(
            [](ICoreWebView2* /*sender*/, ICoreWebView2NewWindowRequestedEventArgs* args) -> HRESULT {
                args->put_Handled(TRUE);
                return S_OK;
            })
            .Get(), &newWindowToken);

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
        case WM_TIMER: OnTimer(); return 0;
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
        case WM_GETMINMAXINFO: {
            auto* mmi = reinterpret_cast<MINMAXINFO*>(lParam);
            mmi->ptMinTrackSize.x = 640;
            mmi->ptMinTrackSize.y = 400;
            return 0;
        }
    }
    return DefWindowProcW(hwnd_, msg, wParam, lParam);
}

} // namespace dsh
