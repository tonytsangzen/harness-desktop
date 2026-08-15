#pragma once

#include <windows.h>

#include <string>

namespace dsh {

// Download bar state marshaled from worker threads (also set directly by the
// WebView2 download handlers on the UI thread).
struct DownloadStatusInfo {
    long long received = 0;
    long long total = -1;
    std::wstring filename;
};

// Owns the Win32 top-level window, the WebView2 controller, the loading
// overlay, and the download bar. All WebView2 COM event handlers and worker
// threads marshal back to the UI thread with PostMessage.
class MainWindow {
public:
    static MainWindow& Instance();

    bool Create(HINSTANCE instance, const std::wstring& title);
    void Show();
    void Run(); // message loop; returns when the window closes
    HWND Hwnd() const { return hwnd_; }
    void Close();

private:
    struct DownloadInfo {
        std::wstring filename;
        long long received = 0;
        long long total = -1;
    };

    HWND hwnd_ = nullptr;
    HWND overlayHwnd_ = nullptr;
    HWND downloadHwnd_ = nullptr;
    bool downloadBarVisible_ = false;
    int spinnerFrame_ = 0;

    std::wstring overlayText_;
    int overlayPercent_ = -1;

    DownloadInfo download_;

    static LRESULT CALLBACK StaticWndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam);
    LRESULT WndProc(UINT msg, WPARAM wParam, LPARAM lParam);

    void OnCreate();
    void OnSize();
    void OnDestroy();
    void OnTimer();

    // Overlay / download bar controls.
    void ShowOverlay();
    void SetOverlayText(const std::wstring& text);
    void SetOverlayProgress(int percent); // -1 = indeterminate
    void ShowDownloadBar();
    void HideDownloadBar();
    void UpdateDownloadBar();
    void LayoutChildWindows();
    void PaintOverlay();
    void PaintDownloadBar();

    // WebView2 initialization (runs on the UI thread).
    void InitWebView2();

    // Message handlers.
    void OnOverlayStatus(const std::wstring* text);
    void OnOverlayProgress(WPARAM encoded);
    void OnDownloadStatus(const DownloadStatusInfo* info);
    void OnShowDownloadBar();
    void OnHideDownloadBar();
    void OnDownloadFailed(const std::wstring* message);
    void OnServerReady();
    void OnServerFailed();
    void OnUpdateAvailable(const std::wstring* version);
    void OnUpdateFinished(bool ok);

    // Background work.
    static DWORD WINAPI EnsureNodeAndStartServer(LPVOID param);
    static DWORD WINAPI CheckForUpdate(LPVOID param);
    static void StartServerThread();
    void PromptForUpdate(const std::wstring& version);
    static DWORD WINAPI RefreshUpdate(LPVOID param);
    void StartNativeDownload(const std::wstring& url, const std::wstring& targetPath);
    static DWORD WINAPI RunNativeDownload(LPVOID param);

    // WebView2 event wiring.
    void ConfigureWebView();
    void WireEvents();

public:
    // Read access for the overlay / download child window paint procs.
    const std::wstring& OverlayText() const { return overlayText_; }
    int OverlayPercent() const { return overlayPercent_; }
    int SpinnerFrame() const { return spinnerFrame_; }
    const std::wstring& DownloadFilename() const { return download_.filename; }
    long long DownloadReceived() const { return download_.received; }
    long long DownloadTotal() const { return download_.total; }
};

// PostMessage helpers shared with worker threads.
void PostOverlayStatus(const std::wstring& text);
void PostOverlayProgress(int percent);
void PostDownloadStatus(long long received, long long total, const std::wstring& filename);
void PostShowDownloadBar();
void PostHideDownloadBar();
void PostDownloadFailed(const std::wstring& message);
void PostServerReady();
void PostServerFailed();
void PostUpdateAvailable(const std::wstring& version);
void PostUpdateFinished(bool ok);

} // namespace dsh
