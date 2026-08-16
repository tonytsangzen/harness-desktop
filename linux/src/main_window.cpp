#include "main_window.h"

#include "node_runtime_manager.h"
#include "server_manager.h"
#include "settings.h"
#include "update_manager.h"
#include "util.h"

#include <glib/gstdio.h>
#include <gio/gio.h>

#include <climits>
#include <cstdio>
#include <string>

#include <unistd.h>

#include <gdk/gdkkeys.h>
#include <gdk/gdkkeysyms.h>

namespace dsh {

namespace {

// ---- small helpers ---------------------------------------------------------

constexpr const char* kSettingsFile = "settings.conf";

// Directory of the running executable (portable tarballs ship the icon next
// to the binary).
std::string ExeDir() {
    char buf[PATH_MAX];
    ssize_t n = readlink("/proc/self/exe", buf, sizeof(buf) - 1);
    if (n <= 0) return {};
    buf[n] = '\0';
    std::string path(buf);
    size_t slash = path.find_last_of('/');
    return slash == std::string::npos ? std::string(".") : path.substr(0, slash);
}

// Sets the window icon: prefer a real icon next to the executable or in the
// installed hicolor theme (PNG first — GdkPixbuf loads it natively; SVG needs
// the librsvg loader), then fall back to the theme by name.
void ApplyWindowIcon() {
    const char* candidates[] = {
        "deepseek-harness.png",
        "/usr/share/icons/hicolor/256x256/apps/deepseek-harness.png",
        "/usr/share/icons/hicolor/scalable/apps/deepseek-harness.svg",
        "deepseek-harness.svg",
    };
    std::string exeDir = ExeDir();
    for (const char* rel : candidates) {
        std::string path = rel[0] == '/' ? std::string(rel) : exeDir + "/" + rel;
        if (!g_file_test(path.c_str(), G_FILE_TEST_EXISTS)) continue;
        GError* error = nullptr;
        GdkPixbuf* pixbuf = gdk_pixbuf_new_from_file(path.c_str(), &error);
        if (error) {
            g_error_free(error);
            continue;
        }
        gtk_window_set_default_icon(pixbuf);
        g_object_unref(pixbuf);
        return;
    }
    gtk_window_set_default_icon_name("deepseek-harness");
}

// Sends a synthetic key press+release to a widget (used by the Edit menu so
// cut/copy/paste work through the focused WebKitWebView).
void SendKey(GtkWidget* widget, guint keyval, GdkModifierType state) {
    gtk_widget_grab_focus(widget);
    // Resolve the keycode from the default keymap (gdk_keyval_to_keycode is
    // X11-only and not available in the generic GDK3 headers).
    guint keycode = 0;
    if (GdkKeymap* keymap = gdk_keymap_get_for_display(gdk_display_get_default())) {
        GdkKeymapKey* keys = nullptr;
        gint n = 0;
        if (gdk_keymap_get_entries_for_keyval(keymap, keyval, &keys, &n) && n > 0 && keys) {
            keycode = keys[0].keycode;
            g_free(keys);
        }
    }
    GdkEventKey press{};
    press.type = GDK_KEY_PRESS;
    press.window = gtk_widget_get_window(widget);
    if (press.window) g_object_ref(press.window);
    press.send_event = TRUE;
    press.time = GDK_CURRENT_TIME;
    press.state = state;
    press.keyval = keyval;
    press.hardware_keycode = keycode;
    press.group = 0;
    press.is_modifier = FALSE;
    gtk_widget_event(widget, reinterpret_cast<GdkEvent*>(&press));
    if (press.window) g_object_unref(press.window);

    GdkEventKey release = press;
    release.type = GDK_KEY_RELEASE;
    gtk_widget_event(widget, reinterpret_cast<GdkEvent*>(&release));
    if (release.window) g_object_unref(release.window);
}

// Edit-menu action ids passed through g_object_set_data.
enum EditAction { kEditUndo, kEditRedo, kEditCut, kEditCopy, kEditPaste, kEditSelectAll };

// Recursively deletes a directory (npx cache cleanup).
void RemoveTree(const std::string& path) {
    GFile* file = g_file_new_for_path(path.c_str());
    g_file_delete(file, nullptr, nullptr);
    g_object_unref(file);
}

// ---- auto-install of a missing Node.js runtime ----

struct NodeInstallCtx {
    MainWindow* self;
    GtkWidget* dialog; // guarded by a weak pointer (NULL once destroyed)
    GtkWidget* progressBar;
    GtkWidget* label;
    gint result = 0; // 1 = installed, 0 = failed (set before the done idle)
};

struct NodeInstallProgress {
    NodeInstallCtx* ctx;
    NodeRuntimeManager::State state;
    double fraction;
};

gboolean OnNodeInstallProgressIdle(gpointer data) {
    auto* p = static_cast<NodeInstallProgress*>(data);
    NodeInstallCtx* ctx = p->ctx;
    if (p->state == NodeRuntimeManager::State::Downloading) {
        if (p->fraction >= 0) {
            char buf[160];
            int percent = static_cast<int>(p->fraction * 100 + 0.5);
            snprintf(buf, sizeof(buf),
                     "正在下载 Node.js（%d%%）… / Downloading Node.js (%d%%)…",
                     percent, percent);
            gtk_label_set_text(GTK_LABEL(ctx->label), buf);
            gtk_progress_bar_set_fraction(GTK_PROGRESS_BAR(ctx->progressBar), p->fraction);
        } else {
            gtk_label_set_text(GTK_LABEL(ctx->label),
                               "正在下载 Node.js… / Downloading Node.js…");
            gtk_progress_bar_pulse(GTK_PROGRESS_BAR(ctx->progressBar));
        }
    } else if (p->state == NodeRuntimeManager::State::Installing) {
        gtk_label_set_text(GTK_LABEL(ctx->label),
                           "正在安装 Node.js… / Installing Node.js…");
        gtk_progress_bar_set_fraction(GTK_PROGRESS_BAR(ctx->progressBar), 1.0);
        gtk_progress_bar_set_text(GTK_PROGRESS_BAR(ctx->progressBar), "");
    }
    delete p;
    return G_SOURCE_REMOVE;
}

// Sole owner of ctx after the worker finishes: reports the outcome through
// the dialog (if it is still alive) and frees ctx. If the user closed the
// dialog early, ctx->dialog is NULL (weak pointer) and only ctx is freed.
gboolean OnNodeInstallDoneIdle(gpointer data) {
    auto* ctx = static_cast<NodeInstallCtx*>(data);
    if (ctx->dialog) {
        // Detach the weak pointer first: gtk_widget_destroy() in
        // StartNodeAutoInstall runs *after* this idle and would otherwise
        // write NULL into the already-freed ctx (heap use-after-free that
        // corrupted GLib's allocator and crashed the following Start()).
        g_object_remove_weak_pointer(G_OBJECT(ctx->dialog),
                                     reinterpret_cast<gpointer*>(&ctx->dialog));
        gtk_dialog_response(GTK_DIALOG(ctx->dialog),
                            ctx->result ? GTK_RESPONSE_OK : GTK_RESPONSE_REJECT);
    }
    delete ctx;
    return G_SOURCE_REMOVE;
}

} // namespace

// ---- lifecycle --------------------------------------------------------------

MainWindow::MainWindow() = default;
MainWindow::~MainWindow() = default;

bool MainWindow::Init(const Settings& settings) {
    settings_ = &settings;

    if (!ServerManager::NodeAvailable(nullptr)) {
        // Report early; the window will show a usable error state.
        g_printerr("dshwebview: node/npx not found on PATH\n");
    }

    LoadSettings();
    BuildUi();

    ServerManager::Initialize(settings);
    StartServerAndPoll();
    return true;
}

void MainWindow::Run() { gtk_main(); }

void MainWindow::Shutdown() { ServerManager::Stop(); }

// ---- preferences -------------------------------------------------------------

void MainWindow::LoadSettings() {
    std::string path = ConfigDir() + "/" + kSettingsFile;
    GKeyFile* kf = g_key_file_new();
    if (g_key_file_load_from_file(kf, path.c_str(), G_KEY_FILE_NONE, nullptr)) {
        if (gchar* v = g_key_file_get_string(kf, "app", "theme", nullptr)) {
            std::string s = v;
            g_free(v);
            if (s == "light") theme_ = Theme::Light;
            else if (s == "dark") theme_ = Theme::Dark;
        }
        if (gchar* v = g_key_file_get_string(kf, "app", "language", nullptr)) {
            std::string s = v;
            g_free(v);
            if (s == "zh") lang_ = Lang::Zh;
            else if (s == "en") lang_ = Lang::En;
        }
    }
    g_key_file_free(kf);
}

void MainWindow::SaveSettings() {
    GKeyFile* kf = g_key_file_new();
    g_key_file_set_string(kf, "app", "theme",
                          theme_ == Theme::Light ? "light" : (theme_ == Theme::Dark ? "dark" : "system"));
    g_key_file_set_string(kf, "app", "language",
                          lang_ == Lang::Zh ? "zh" : (lang_ == Lang::En ? "en" : "system"));
    gsize len = 0;
    gchar* data = g_key_file_to_data(kf, &len, nullptr);
    if (data) {
        WriteFileText(ConfigDir() + "/" + kSettingsFile, std::string(data, len));
        g_free(data);
    }
    g_key_file_free(kf);
}

bool MainWindow::IsChinese() const {
    if (lang_ != Lang::System) return lang_ == Lang::Zh;
    return SystemLanguageIsChinese();
}

// ---- UI ----------------------------------------------------------------------

void MainWindow::BuildUi() {
    ApplyWindowIcon();

    window_ = gtk_window_new(GTK_WINDOW_TOPLEVEL);
    gtk_window_set_title(GTK_WINDOW(window_), "DeepSeek Harness");
    gtk_window_set_default_size(GTK_WINDOW(window_), 1280, 800);
    gtk_window_set_position(GTK_WINDOW(window_), GTK_WIN_POS_CENTER);
    g_signal_connect(window_, "delete-event", G_CALLBACK(OnWindowDelete), this);

    // One accel group drives the Edit menu shortcuts for the whole session.
    accelGroup_ = gtk_accel_group_new();
    gtk_window_add_accel_group(GTK_WINDOW(window_), accelGroup_);

    GtkWidget* vbox = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_container_add(GTK_CONTAINER(window_), vbox);

    // Menu bar (rebuilt when the language changes).
    menubar_ = gtk_menu_bar_new();
    gtk_box_pack_start(GTK_BOX(vbox), menubar_, FALSE, FALSE, 0);
    RebuildMenu();

    // Web view.
    webSettings_ = webkit_settings_new();
    webkit_settings_set_enable_developer_extras(webSettings_, FALSE);
    webkit_settings_set_enable_write_console_messages_to_stdout(webSettings_, TRUE);
    g_object_ref_sink(webSettings_); // own the floating reference

    webview_ = webkit_web_view_new_with_settings(webSettings_);
    g_signal_connect(webview_, "decide-policy", G_CALLBACK(OnDecidePolicy), this);
    g_signal_connect(webview_, "create", G_CALLBACK(OnCreateWebView), this);
    g_signal_connect(webview_, "load-changed", G_CALLBACK(OnLoadChanged), this);
    g_signal_connect(webview_, "load-failed", G_CALLBACK(OnLoadFailed), this);
    // Newer WebKitGTK renamed the WebKitWebContext download signal to
    // "download-started"; probe so both the 2.36 baseline and current
    // releases work (a failed connect only warns and silently disables
    // page downloads).
    WebKitWebContext* webContext = webkit_web_context_get_default();
    const char* downloadSignal = g_signal_lookup("download-start", WEBKIT_TYPE_WEB_CONTEXT)
                                     ? "download-start"
                                     : "download-started";
    g_signal_connect(webContext, downloadSignal, G_CALLBACK(OnDownloadStart), this);

    // Loading overlay (spinner while the server / first page comes up).
    GtkWidget* overlay = gtk_overlay_new();
    gtk_box_pack_start(GTK_BOX(vbox), overlay, TRUE, TRUE, 0);
    gtk_container_add(GTK_CONTAINER(overlay), webview_);

    loadingOverlay_ = gtk_box_new(GTK_ORIENTATION_VERTICAL, 12);
    gtk_widget_set_halign(loadingOverlay_, GTK_ALIGN_CENTER);
    gtk_widget_set_valign(loadingOverlay_, GTK_ALIGN_CENTER);
    GtkWidget* spinner = gtk_spinner_new();
    gtk_spinner_start(GTK_SPINNER(spinner));
    GtkWidget* label = gtk_label_new(IsChinese() ? "正在启动 DeepSeek Harness…" : "Starting DeepSeek Harness…");
    gtk_box_pack_start(GTK_BOX(loadingOverlay_), spinner, FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(loadingOverlay_), label, FALSE, FALSE, 0);
    // Hint shown only when startup drags on (first run installs the dsh
    // dependency tree through npx, which can take several minutes).
    loadingHint_ = gtk_label_new("");
    gtk_style_context_add_class(gtk_widget_get_style_context(loadingHint_), "dim-label");
    gtk_box_pack_start(GTK_BOX(loadingOverlay_), loadingHint_, FALSE, FALSE, 0);
    gtk_widget_set_no_show_all(loadingHint_, TRUE);
    gtk_overlay_add_overlay(GTK_OVERLAY(overlay), loadingOverlay_);

    // Download progress bar (hidden until a download starts).
    progressBox_ = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    gtk_container_set_border_width(GTK_CONTAINER(progressBox_), 4);
    progressLabel_ = gtk_label_new("");
    progressBar_ = gtk_progress_bar_new();
    gtk_progress_bar_set_show_text(GTK_PROGRESS_BAR(progressBar_), TRUE);
    gtk_box_pack_start(GTK_BOX(progressBox_), progressLabel_, FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(progressBox_), progressBar_, TRUE, TRUE, 0);
    gtk_box_pack_start(GTK_BOX(vbox), progressBox_, FALSE, FALSE, 0);
    gtk_widget_set_no_show_all(progressBox_, TRUE);
    SetDownloadProgressVisible(false);

    // Remember the default dark preference so "Follow System" can restore it.
    GtkSettings* gs = gtk_settings_get_default();
    g_object_get(gs, "gtk-application-prefer-dark-theme", &initialDarkPref_, nullptr);

    ApplyTheme();
    gtk_widget_show_all(window_);
    gtk_widget_hide(loadingOverlay_); // shown again by OnLoadChanged while loading
}

void MainWindow::RebuildMenu() {
    if (!window_) return;
    if (menubar_) {
        gtk_widget_destroy(menubar_);
        menubar_ = nullptr;
    }
    menubar_ = gtk_menu_bar_new();

    bool zh = IsChinese();

    // ---- Edit menu (clipboard accelerators for the webview) ----
    {
        GtkWidget* editItem = gtk_menu_item_new_with_label(zh ? "编辑" : "Edit");
        GtkWidget* editMenu = gtk_menu_new();
        struct Entry { const char* label; guint key; GdkModifierType mods; EditAction action; };
        const Entry entries[] = {
            { zh ? "撤销" : "Undo", GDK_KEY_z, GDK_CONTROL_MASK, kEditUndo },
            { zh ? "重做" : "Redo", GDK_KEY_z,
              static_cast<GdkModifierType>(GDK_CONTROL_MASK | GDK_SHIFT_MASK), kEditRedo },
            { zh ? "剪切" : "Cut", GDK_KEY_x, GDK_CONTROL_MASK, kEditCut },
            { zh ? "拷贝" : "Copy", GDK_KEY_c, GDK_CONTROL_MASK, kEditCopy },
            { zh ? "粘贴" : "Paste", GDK_KEY_v, GDK_CONTROL_MASK, kEditPaste },
            { zh ? "全选" : "Select All", GDK_KEY_a, GDK_CONTROL_MASK, kEditSelectAll },
        };
        for (const auto& e : entries) {
            GtkWidget* item = gtk_menu_item_new_with_label(e.label);
            g_object_set_data(G_OBJECT(item), "edit-action", GINT_TO_POINTER(e.action));
            gtk_widget_add_accelerator(item, "activate", accelGroup_, e.key, e.mods, GTK_ACCEL_VISIBLE);
            g_signal_connect(item, "activate", G_CALLBACK(OnEditActivate), this);
            gtk_menu_shell_append(GTK_MENU_SHELL(editMenu), item);
        }
        gtk_menu_item_set_submenu(GTK_MENU_ITEM(editItem), editMenu);
        gtk_menu_shell_append(GTK_MENU_SHELL(menubar_), editItem);
    }

    // ---- Theme menu ----
    {
        GtkWidget* themeItem = gtk_menu_item_new_with_label(zh ? "主题" : "Theme");
        GtkWidget* themeMenu = gtk_menu_new();
        GSList* group = nullptr;
        struct Entry { const char* label; Theme theme; };
        const Entry entries[] = {
            { zh ? "跟随系统" : "Follow System", Theme::System },
            { zh ? "明亮" : "Light", Theme::Light },
            { zh ? "暗黑" : "Dark", Theme::Dark },
        };
        for (const auto& e : entries) {
            GtkWidget* item = gtk_radio_menu_item_new_with_label(group, e.label);
            group = gtk_radio_menu_item_get_group(GTK_RADIO_MENU_ITEM(item));
            g_object_set_data(G_OBJECT(item), "theme-value", GINT_TO_POINTER(static_cast<int>(e.theme)));
            if (theme_ == e.theme) gtk_check_menu_item_set_active(GTK_CHECK_MENU_ITEM(item), TRUE);
            g_signal_connect(item, "toggled", G_CALLBACK(OnThemeToggled), this);
            gtk_menu_shell_append(GTK_MENU_SHELL(themeMenu), item);
        }
        gtk_menu_item_set_submenu(GTK_MENU_ITEM(themeItem), themeMenu);
        gtk_menu_shell_append(GTK_MENU_SHELL(menubar_), themeItem);
    }

    // ---- Language menu ----
    {
        GtkWidget* langItem = gtk_menu_item_new_with_label(zh ? "语言" : "Language");
        GtkWidget* langMenu = gtk_menu_new();
        GSList* group = nullptr;
        struct Entry { const char* label; Lang lang; };
        const Entry entries[] = {
            { zh ? "跟随系统" : "Follow System", Lang::System },
            { "简体中文", Lang::Zh },
            { "English", Lang::En },
        };
        for (const auto& e : entries) {
            GtkWidget* item = gtk_radio_menu_item_new_with_label(group, e.label);
            group = gtk_radio_menu_item_get_group(GTK_RADIO_MENU_ITEM(item));
            g_object_set_data(G_OBJECT(item), "lang-value", GINT_TO_POINTER(static_cast<int>(e.lang)));
            if (lang_ == e.lang) gtk_check_menu_item_set_active(GTK_CHECK_MENU_ITEM(item), TRUE);
            g_signal_connect(item, "toggled", G_CALLBACK(OnLangToggled), this);
            gtk_menu_shell_append(GTK_MENU_SHELL(langMenu), item);
        }
        gtk_menu_item_set_submenu(GTK_MENU_ITEM(langItem), langMenu);
        gtk_menu_shell_append(GTK_MENU_SHELL(menubar_), langItem);
    }

    // ---- Full screen ----
    {
        GtkWidget* item = gtk_check_menu_item_new_with_label(zh ? "全屏" : "Full Screen");
        if (fullscreen_) gtk_check_menu_item_set_active(GTK_CHECK_MENU_ITEM(item), TRUE);
        g_signal_connect(item, "toggled", G_CALLBACK(OnFullScreenToggled), this);
        gtk_menu_shell_append(GTK_MENU_SHELL(menubar_), item);
    }

    // ---- Plugins Market ----
    {
        GtkWidget* item = gtk_menu_item_new_with_label(zh ? "插件市场" : "Plugins Market");
        g_signal_connect(item, "activate", G_CALLBACK(OnPluginsMarketActivate), this);
        gtk_menu_shell_append(GTK_MENU_SHELL(menubar_), item);
    }

    // Re-insert the fresh menu bar at the top of the main vbox (index 0).
    GtkWidget* box = gtk_bin_get_child(GTK_BIN(window_));
    gtk_box_pack_start(GTK_BOX(box), menubar_, FALSE, FALSE, 0);
    gtk_box_reorder_child(GTK_BOX(box), menubar_, 0);
    gtk_widget_show_all(menubar_);
}

void MainWindow::ApplyTheme() {
    GtkSettings* gs = gtk_settings_get_default();
    if (theme_ == Theme::Dark) {
        g_object_set(gs, "gtk-application-prefer-dark-theme", TRUE, nullptr);
    } else if (theme_ == Theme::Light) {
        g_object_set(gs, "gtk-application-prefer-dark-theme", FALSE, nullptr);
    } else {
        g_object_set(gs, "gtk-application-prefer-dark-theme", initialDarkPref_, nullptr);
    }
    if (webSettings_) {
        // Drive the web content's prefers-color-scheme through the explicit
        // WebKitGTK property when available (added in 2.38). On older releases
        // (e.g. Ubuntu 22.04's 2.36) the property does not exist and the media
        // query follows the GTK dark variant set above — same visible result.
        GParamSpec* pspec = g_object_class_find_property(
            G_OBJECT_GET_CLASS(webSettings_), "preferred-color-scheme");
        if (pspec) {
            // WebKitPreferredColorScheme: AUTO=0, LIGHT=1, DARK=2.
            guint scheme = theme_ == Theme::Light ? 1 : (theme_ == Theme::Dark ? 2 : 0);
            g_object_set(webSettings_, "preferred-color-scheme", scheme, nullptr);
        }
    }
}

void MainWindow::SetTheme(Theme theme) {
    if (theme_ == theme) return;
    theme_ = theme;
    SaveSettings();
    ApplyTheme();
    RebuildMenu(); // refresh radio state
}

void MainWindow::SetLang(Lang lang) {
    if (lang_ == lang) return;
    lang_ = lang;
    SaveSettings();
    RebuildMenu();
}

void MainWindow::ToggleFullScreen() {
    togglingFullscreen_ = true;
    if (fullscreen_) {
        gtk_window_unfullscreen(GTK_WINDOW(window_));
        fullscreen_ = false;
    } else {
        gtk_window_fullscreen(GTK_WINDOW(window_));
        fullscreen_ = true;
    }
    togglingFullscreen_ = false;
}

void MainWindow::SetLoadingOverlay(bool visible) {
    if (loadingOverlay_) {
        if (visible) gtk_widget_show(loadingOverlay_);
        else gtk_widget_hide(loadingOverlay_);
    }
}

void MainWindow::SetDownloadProgressVisible(bool visible) {
    if (progressBox_) {
        if (visible) gtk_widget_show(progressBox_);
        else gtk_widget_hide(progressBox_);
    }
}

void MainWindow::ShowError(const std::string& message) {
    GtkWidget* dialog = gtk_message_dialog_new(
        GTK_WINDOW(window_),
        static_cast<GtkDialogFlags>(GTK_DIALOG_MODAL | GTK_DIALOG_DESTROY_WITH_PARENT),
        GTK_MESSAGE_ERROR, GTK_BUTTONS_OK, "%s", message.c_str());
    gtk_dialog_run(GTK_DIALOG(dialog));
    gtk_widget_destroy(dialog);
}

void MainWindow::OpenExternal(const std::string& uri) {
    // A new-window request can surface through both the "create" signal and a
    // NEW_WINDOW_ACTION policy check; dedupe identical requests within 2 s so
    // the browser is never asked to open the same URL twice.
    gint64 now = g_get_monotonic_time();
    if (uri == lastExternalOpened_ && now - lastExternalOpenedUs_ < 2 * G_USEC_PER_SEC) return;
    lastExternalOpened_ = uri;
    lastExternalOpenedUs_ = now;
    GError* error = nullptr;
    if (!g_app_info_launch_default_for_uri(uri.c_str(), nullptr, &error)) {
        if (error) {
            g_printerr("dshwebview: failed to open %s: %s\n", uri.c_str(), error->message);
            g_error_free(error);
        }
    }
}

bool MainWindow::IsAppUrl(const std::string& uri) const {
    // Only pages served by the local dsh server navigate inside the webview.
    std::string prefix = "http://" + settings_->host + ":" + std::to_string(ServerManager::ActivePort());
    if (uri.compare(0, prefix.size(), prefix) != 0) return false;
    std::string rest = uri.substr(prefix.size());
    if (rest.empty() || rest[0] == '/' || rest[0] == '?' || rest[0] == '#') return true;
    return false;
}

// ---- server lifecycle ---------------------------------------------------------

void MainWindow::StartServerAndPoll() {
    SetLoadingOverlay(true);
    if (!ServerManager::Start()) {
        OnServerFailed();
        return;
    }
    pollStartedUs_ = g_get_monotonic_time();
    g_timeout_add(250, OnPollServer, this);
}

gboolean MainWindow::OnPollServer(gpointer userData) {
    auto* self = static_cast<MainWindow*>(userData);
    if (self->serverReady_) return G_SOURCE_REMOVE;
    // First run installs @deepseek-ai/dsh's dependency tree through npx. The
    // child stays alive while installing, but a 3-minute cap keeps a hung npx
    // from blocking forever; the loading overlay hints what is going on.
    if (!ServerManager::IsRunning()) {
        self->OnServerFailed();
        return G_SOURCE_REMOVE;
    }
    const gint64 elapsedUs = g_get_monotonic_time() - self->pollStartedUs_;
    if (elapsedUs > 180 * G_USEC_PER_SEC) {
        self->OnServerFailed();
        return G_SOURCE_REMOVE;
    }
    if (ServerManager::TcpProbe(self->settings_->host, ServerManager::ActivePort(), 300)) {
        self->OnServerReady();
        return G_SOURCE_REMOVE;
    }
    // After 30 seconds of waiting, tell the user what is going on: the first
    // launch installs @deepseek-ai/dsh through npx and can take a while.
    if (elapsedUs > 30 * G_USEC_PER_SEC && self->loadingHint_ &&
        !gtk_widget_get_visible(self->loadingHint_)) {
        gtk_label_set_text(GTK_LABEL(self->loadingHint_),
                           self->IsChinese()
                               ? "首次启动正在下载依赖，可能需要几分钟…"
                               : "First launch is downloading dependencies — this can take a few minutes…");
        gtk_widget_show(self->loadingHint_);
    }
    return G_SOURCE_CONTINUE;
}

void MainWindow::OnServerReady() {
    serverReady_ = true;
    std::string url = "http://" + settings_->host + ":" +
                      std::to_string(ServerManager::ActivePort()) + "/";
    webkit_web_view_load_uri(WEBKIT_WEB_VIEW(webview_), url.c_str());
    // Version check runs once per session, off the main thread.
    if (!updateChecked_) {
        updateChecked_ = true;
        g_thread_unref(g_thread_new("update-check", CheckForUpdatesThread, this));
    }
}

void MainWindow::OnServerFailed() {
    serverReady_ = true; // stop polling
    SetLoadingOverlay(false);
    std::string missing;
    if (!ServerManager::NodeAvailable(&missing)) {
        // No node/npx anywhere: install a user-level runtime automatically
        // (mirrors macOS/Windows; no root needed).
        StartNodeAutoInstall();
        return;
    }
    ShowError("DeepSeek Harness 服务启动失败。\n\n请查看日志：\n" +
              ServerManager::LogPath() +
              "\n\nFailed to start the DeepSeek Harness server. See the log file above.");
}

void MainWindow::StartNodeAutoInstall() {
    if (nodeInstalling_) return;
    nodeInstalling_ = true;

    GtkWidget* dialog = gtk_dialog_new();
    gtk_window_set_title(GTK_WINDOW(dialog), "DeepSeek Harness");
    gtk_window_set_transient_for(GTK_WINDOW(dialog), GTK_WINDOW(window_));
    gtk_window_set_modal(GTK_WINDOW(dialog), TRUE);
    gtk_window_set_resizable(GTK_WINDOW(dialog), FALSE);
    GtkWidget* content = gtk_dialog_get_content_area(GTK_DIALOG(dialog));
    GtkWidget* label =
        gtk_label_new("正在准备 Node.js 运行时… / Preparing the Node.js runtime…");
    GtkWidget* bar = gtk_progress_bar_new();
    gtk_progress_bar_set_show_text(GTK_PROGRESS_BAR(bar), TRUE);
    gtk_progress_bar_set_fraction(GTK_PROGRESS_BAR(bar), 0.0);
    gtk_box_pack_start(GTK_BOX(content), label, FALSE, FALSE, 10);
    gtk_box_pack_start(GTK_BOX(content), bar, FALSE, FALSE, 10);
    gtk_widget_show_all(dialog);

    auto* ctx = new NodeInstallCtx{this, dialog, bar, label};
    g_object_add_weak_pointer(G_OBJECT(dialog), reinterpret_cast<gpointer*>(&ctx->dialog));
    g_thread_unref(g_thread_new("node-install", NodeInstallThread, ctx));

    gint response = gtk_dialog_run(GTK_DIALOG(dialog));
    gtk_widget_destroy(dialog);
    nodeInstalling_ = false;

    if (response == GTK_RESPONSE_OK) {
        // The runtime is installed and on PATH now — start the server again.
        // OnServerFailed() hid the loading overlay; bring it back so the
        // window shows progress instead of a blank webview while npx spins up.
        SetLoadingOverlay(true);
        NodeRuntimeManager::EnsureOnPath();
        ServerManager::Start();
        serverReady_ = false;
        pollStartedUs_ = g_get_monotonic_time();
        g_timeout_add(250, OnPollServer, this);
    } else {
        ShowError("自动安装 Node.js 失败。\n\n请检查网络后重试，或手动安装：\n"
                  "  sudo apt install nodejs npm\n"
                  "或使用 nvm：https://github.com/nvm-sh/nvm\n\n"
                  "Automatic Node.js install failed. Check your network and retry, "
                  "or install Node.js 18+ (with npm/npx) manually.");
    }
}

gpointer MainWindow::NodeInstallThread(gpointer userData) {
    auto* ctx = static_cast<NodeInstallCtx*>(userData);
    bool ok = NodeRuntimeManager::Provide([ctx](NodeRuntimeManager::State state, double fraction) {
        auto* p = new NodeInstallProgress{ctx, state, fraction};
        g_idle_add(OnNodeInstallProgressIdle, p);
    });
    ctx->result = ok ? 1 : 0;
    g_idle_add(OnNodeInstallDoneIdle, ctx);
    return nullptr;
}

// ---- update check ---------------------------------------------------------------

gpointer MainWindow::CheckForUpdatesThread(gpointer userData) {
    auto* self = static_cast<MainWindow*>(userData);
    std::string latest;
    bool available = UpdateManager::UpdateAvailable(&latest);
    if (available) {
        struct UpdateInfo { MainWindow* self; std::string version; };
        auto* info = new UpdateInfo{ self, latest };
        g_idle_add([](gpointer data) -> gboolean {
            auto* info = static_cast<UpdateInfo*>(data);
            MainWindow* self = info->self;
            GtkWidget* dialog = gtk_message_dialog_new(
                GTK_WINDOW(self->window_), GTK_DIALOG_DESTROY_WITH_PARENT,
                GTK_MESSAGE_QUESTION, GTK_BUTTONS_NONE,
                "发现新版本 %s\n\n检测到 @deepseek-ai/dsh %s 已发布，是否立即更新？"
                "（将刷新 npx 缓存并重启服务）\n\n"
                "A new version %s of @deepseek-ai/dsh is available. Update now?"
                " (refreshes the npx cache and restarts the server)",
                info->version.c_str(), info->version.c_str(), info->version.c_str());
            gtk_dialog_add_buttons(GTK_DIALOG(dialog),
                                   "稍后 / Later", GTK_RESPONSE_CANCEL,
                                   "更新 / Update", GTK_RESPONSE_ACCEPT, nullptr);
            gint response = gtk_dialog_run(GTK_DIALOG(dialog));
            gtk_widget_destroy(dialog);
            if (response == GTK_RESPONSE_ACCEPT) {
                // Drop the cached package so npx re-resolves the latest.
                const char* home = g_getenv("HOME");
                if (home) {
                    std::string npx = std::string(home) + "/.npm/_npx";
                    GDir* dir = g_dir_open(npx.c_str(), 0, nullptr);
                    if (dir) {
                        const char* name = nullptr;
                        while ((name = g_dir_read_name(dir)) != nullptr) {
                            RemoveTree(npx + "/" + name + "/node_modules/@deepseek-ai/dsh");
                        }
                        g_dir_close(dir);
                    }
                }
                // Restart the server and re-poll until it is ready again.
                ServerManager::Stop();
                ServerManager::Start();
                self->serverReady_ = false;
                self->pollStartedUs_ = g_get_monotonic_time();
                g_timeout_add(250, OnPollServer, self);
            }
            delete info;
            return G_SOURCE_REMOVE;
        }, info);
    }
    return nullptr;
}

// ---- WebKit callbacks -----------------------------------------------------------

void MainWindow::OnDecidePolicy(WebKitWebView* /*webView*/, WebKitPolicyDecision* decision,
                                WebKitPolicyDecisionType type, gpointer userData) {
    auto* self = static_cast<MainWindow*>(userData);
    if (type == WEBKIT_POLICY_DECISION_TYPE_NAVIGATION_ACTION) {
        WebKitNavigationAction* action =
            webkit_navigation_policy_decision_get_navigation_action(
                WEBKIT_NAVIGATION_POLICY_DECISION(decision));
        const gchar* uri = nullptr;
        if (WebKitURIRequest* request = webkit_navigation_action_get_request(action)) {
            uri = webkit_uri_request_get_uri(request);
        }
        if (uri && uri[0] && !self->IsAppUrl(uri)) {
            // External target → system default browser, never inside the webview.
            self->OpenExternal(uri);
            webkit_policy_decision_ignore(decision);
            return;
        }
    } else if (type == WEBKIT_POLICY_DECISION_TYPE_NEW_WINDOW_ACTION) {
        // New windows are opened externally by OnCreateWebView; just veto the
        // in-shell navigation here (OpenExternal dedupes identical requests).
        webkit_policy_decision_ignore(decision);
        return;
    }
    webkit_policy_decision_use(decision);
}

WebKitWebView* MainWindow::OnCreateWebView(WebKitWebView* /*webView*/,
                                           WebKitNavigationAction* action, gpointer userData) {
    auto* self = static_cast<MainWindow*>(userData);
    // New-window requests (target="_blank", window.open) open in the system
    // default browser; never create a second window inside the shell.
    if (action) {
        if (WebKitURIRequest* request = webkit_navigation_action_get_request(action)) {
            if (const gchar* uri = webkit_uri_request_get_uri(request); uri && uri[0]) {
                self->OpenExternal(uri);
            }
        }
    }
    return nullptr;
}

void MainWindow::OnLoadChanged(WebKitWebView* /*webView*/, WebKitLoadEvent event, gpointer userData) {
    auto* self = static_cast<MainWindow*>(userData);
    if (event == WEBKIT_LOAD_STARTED) {
        self->SetLoadingOverlay(true);
    } else if (event == WEBKIT_LOAD_FINISHED) {
        self->SetLoadingOverlay(false);
    }
}

void MainWindow::OnLoadFailed(WebKitWebView* /*webView*/, WebKitLoadEvent /*event*/,
                              const gchar* /*failingUri*/, GError* error, gpointer userData) {
    auto* self = static_cast<MainWindow*>(userData);
    self->SetLoadingOverlay(false);
    if (error && error->code != WEBKIT_NETWORK_ERROR_CANCELLED) {
        g_printerr("dshwebview: page load failed: %s\n", error->message);
    }
}

// ---- downloads -------------------------------------------------------------------

void MainWindow::OnDownloadStart(WebKitWebContext* /*context*/, WebKitDownload* download,
                                 gpointer userData) {
    auto* self = static_cast<MainWindow*>(userData);
    g_signal_connect(download, "decide-destination", G_CALLBACK(OnDecideDestination), self);
    g_signal_connect(download, "notify::estimated-progress", G_CALLBACK(OnDownloadProgress), self);
    g_signal_connect(download, "finished", G_CALLBACK(OnDownloadFinished), self);
    g_signal_connect(download, "failed", G_CALLBACK(OnDownloadFailed), self);
}

gboolean MainWindow::OnDecideDestination(WebKitDownload* download, const gchar* suggestedFilename,
                                         gpointer userData) {
    auto* self = static_cast<MainWindow*>(userData);
    std::string initial;
    const char* home = g_getenv("HOME");
    if (home) initial = std::string(home) + "/Downloads";
    GtkWidget* chooser = gtk_file_chooser_dialog_new(
        "Save As / 另存为", GTK_WINDOW(self->window_), GTK_FILE_CHOOSER_ACTION_SAVE,
        "取消 / Cancel", GTK_RESPONSE_CANCEL,
        "保存 / Save", GTK_RESPONSE_ACCEPT, nullptr);
    if (!initial.empty()) gtk_file_chooser_set_current_folder(GTK_FILE_CHOOSER(chooser), initial.c_str());
    if (suggestedFilename) {
        gtk_file_chooser_set_current_name(GTK_FILE_CHOOSER(chooser), suggestedFilename);
    }
    gint response = gtk_dialog_run(GTK_DIALOG(chooser));
    if (response == GTK_RESPONSE_ACCEPT) {
        gchar* filename = gtk_file_chooser_get_filename(GTK_FILE_CHOOSER(chooser));
        if (filename) {
            gchar* uri = g_filename_to_uri(filename, nullptr, nullptr);
            if (uri) {
                webkit_download_set_destination(download, uri);
                g_free(uri);
            }
            g_free(filename);
        }
    } else {
        webkit_download_cancel(download);
    }
    gtk_widget_destroy(chooser);
    return TRUE;
}

void MainWindow::OnDownloadProgress(WebKitDownload* download, GParamSpec* /*param*/,
                                    gpointer userData) {
    auto* self = static_cast<MainWindow*>(userData);
    double progress = webkit_download_get_estimated_progress(download);
    gtk_progress_bar_set_fraction(GTK_PROGRESS_BAR(self->progressBar_), progress);
    char text[64];
    std::snprintf(text, sizeof(text), "%.0f%%", progress * 100.0);
    gtk_progress_bar_set_text(GTK_PROGRESS_BAR(self->progressBar_), text);
    self->SetDownloadProgressVisible(true);
}

void MainWindow::OnDownloadFinished(WebKitDownload* /*download*/, gpointer userData) {
    auto* self = static_cast<MainWindow*>(userData);
    gtk_progress_bar_set_fraction(GTK_PROGRESS_BAR(self->progressBar_), 1.0);
    gtk_progress_bar_set_text(GTK_PROGRESS_BAR(self->progressBar_),
                              self->IsChinese() ? "下载完成 / Done" : "Done");
}

void MainWindow::OnDownloadFailed(WebKitDownload* /*download*/, GError* error, gpointer userData) {
    auto* self = static_cast<MainWindow*>(userData);
    if (error && error->code != WEBKIT_DOWNLOAD_ERROR_CANCELLED_BY_USER) {
        g_printerr("dshwebview: download failed: %s\n", error->message);
    }
    self->SetDownloadProgressVisible(false);
}

// ---- menu callbacks ---------------------------------------------------------------

gboolean MainWindow::OnWindowDelete(GtkWidget* /*widget*/, GdkEvent* /*event*/, gpointer userData) {
    auto* self = static_cast<MainWindow*>(userData);
    self->Shutdown();
    gtk_main_quit();
    return FALSE;
}

void MainWindow::OnThemeToggled(GtkWidget* item, gpointer userData) {
    auto* self = static_cast<MainWindow*>(userData);
    if (!gtk_check_menu_item_get_active(GTK_CHECK_MENU_ITEM(item))) return;
    int value = GPOINTER_TO_INT(g_object_get_data(G_OBJECT(item), "theme-value"));
    self->SetTheme(static_cast<Theme>(value));
}

void MainWindow::OnLangToggled(GtkWidget* item, gpointer userData) {
    auto* self = static_cast<MainWindow*>(userData);
    if (!gtk_check_menu_item_get_active(GTK_CHECK_MENU_ITEM(item))) return;
    int value = GPOINTER_TO_INT(g_object_get_data(G_OBJECT(item), "lang-value"));
    self->SetLang(static_cast<Lang>(value));
}

void MainWindow::OnFullScreenToggled(GtkWidget* item, gpointer userData) {
    auto* self = static_cast<MainWindow*>(userData);
    if (self->togglingFullscreen_) return;
    if (gtk_check_menu_item_get_active(GTK_CHECK_MENU_ITEM(item))) {
        if (!self->fullscreen_) self->ToggleFullScreen();
    } else {
        if (self->fullscreen_) self->ToggleFullScreen();
    }
}

void MainWindow::OnPluginsMarketActivate(GtkWidget* /*item*/, gpointer userData) {
    auto* self = static_cast<MainWindow*>(userData);
    self->OpenExternal("https://tonytsangzen.github.io/harness-market/");
}

void MainWindow::OnEditActivate(GtkWidget* item, gpointer userData) {
    auto* self = static_cast<MainWindow*>(userData);
    if (!self->webview_) return;
    int action = GPOINTER_TO_INT(g_object_get_data(G_OBJECT(item), "edit-action"));
    switch (action) {
        case kEditUndo: SendKey(self->webview_, GDK_KEY_z, GDK_CONTROL_MASK); break;
        case kEditRedo: SendKey(self->webview_, GDK_KEY_z,
                                static_cast<GdkModifierType>(GDK_CONTROL_MASK | GDK_SHIFT_MASK)); break;
        case kEditCut: SendKey(self->webview_, GDK_KEY_x, GDK_CONTROL_MASK); break;
        case kEditCopy: SendKey(self->webview_, GDK_KEY_c, GDK_CONTROL_MASK); break;
        case kEditPaste: SendKey(self->webview_, GDK_KEY_v, GDK_CONTROL_MASK); break;
        case kEditSelectAll: SendKey(self->webview_, GDK_KEY_a, GDK_CONTROL_MASK); break;
    }
}

} // namespace dsh
