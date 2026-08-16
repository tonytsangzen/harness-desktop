#pragma once

#include <gtk/gtk.h>
#include <webkit2/webkit2.h>

#include <string>

namespace dsh {

struct Settings;

// Owns the GTK window, the menu bar, the WebKitWebView, the loading overlay,
// and the download progress bar. Mirrors the macOS/Windows MainWindow.
class MainWindow {
public:
    // UI theme: follow the OS, force light, or force dark.
    enum class Theme { System = 0, Light = 1, Dark = 2 };
    // Menu language: follow the OS locale, force Chinese, or force English.
    enum class Lang { System = 0, Zh = 1, En = 2 };

    MainWindow();
    ~MainWindow();

    bool Init(const Settings& settings); // build UI + start the server
    void Run();                           // gtk_main
    void Shutdown();                      // stop the server

private:
    // ---- state ----
    const Settings* settings_ = nullptr;

    GtkWidget* window_ = nullptr;
    GtkWidget* menubar_ = nullptr;
    GtkAccelGroup* accelGroup_ = nullptr;
    GtkWidget* webview_ = nullptr;
    WebKitSettings* webSettings_ = nullptr;
    GtkWidget* loadingOverlay_ = nullptr;
    GtkWidget* progressBox_ = nullptr;
    GtkWidget* progressLabel_ = nullptr;
    GtkWidget* progressBar_ = nullptr;

    Theme theme_ = Theme::System;
    Lang lang_ = Lang::System;
    gboolean initialDarkPref_ = FALSE; // captured before any theme override
    bool fullscreen_ = false;
    bool togglingFullscreen_ = false;
    bool serverReady_ = false;
    bool updateChecked_ = false;
    gint64 pollStartedUs_ = 0;
    std::string lastExternalOpened_; // dedupe identical external-open requests
    gint64 lastExternalOpenedUs_ = 0;

    // ---- preferences (~/.config/deepseek-harness/settings.conf) ----
    void LoadSettings();
    void SaveSettings();
    bool IsChinese() const;

    // ---- UI ----
    void BuildUi();
    void RebuildMenu();
    void ApplyTheme();
    void SetTheme(Theme theme);
    void SetLang(Lang lang);
    void ToggleFullScreen();
    void SetLoadingOverlay(bool visible);
    void SetDownloadProgressVisible(bool visible);
    void ShowError(const std::string& message);
    void OpenExternal(const std::string& uri);
    bool IsAppUrl(const std::string& uri) const;

    // ---- server lifecycle ----
    void StartServerAndPoll();
    static gboolean OnPollServer(gpointer userData);
    void OnServerReady();
    void OnServerFailed();

    // ---- update check ----
    void CheckForUpdates();
    void RefreshAndRestart();
    static gpointer CheckForUpdatesThread(gpointer userData);

    // ---- WebKit callbacks ----
    static void OnDecidePolicy(WebKitWebView* webView, WebKitPolicyDecision* decision,
                               WebKitPolicyDecisionType type, gpointer userData);
    static WebKitWebView* OnCreateWebView(WebKitWebView* webView,
                                          WebKitNavigationAction* action, gpointer userData);
    static void OnLoadChanged(WebKitWebView* webView, WebKitLoadEvent event, gpointer userData);
    static void OnDownloadStart(WebKitWebContext* context, WebKitDownload* download, gpointer userData);
    static gboolean OnDecideDestination(WebKitDownload* download, const gchar* suggestedFilename, gpointer userData);
    static void OnDownloadProgress(WebKitDownload* download, GParamSpec* param, gpointer userData);
    static void OnDownloadFinished(WebKitDownload* download, gpointer userData);
    static void OnDownloadFailed(WebKitDownload* download, GError* error, gpointer userData);

    // ---- menu callbacks ----
    static gboolean OnWindowDelete(GtkWidget* widget, GdkEvent* event, gpointer userData);
    static void OnThemeToggled(GtkWidget* item, gpointer userData);
    static void OnLangToggled(GtkWidget* item, gpointer userData);
    static void OnFullScreenToggled(GtkWidget* item, gpointer userData);
    static void OnPluginsMarketActivate(GtkWidget* item, gpointer userData);
    static void OnEditActivate(GtkWidget* item, gpointer userData);
};

} // namespace dsh
