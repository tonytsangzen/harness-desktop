#include "plugins_manager.h"

#include "json.h"
#include "util.h"

#include <libsoup/soup.h>

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <set>
#include <string>

#include <glib.h>

namespace dsh {
namespace PluginsManager {

// ---------------------------------------------------------------------------
// Data layer (blocking; the dialog calls these from worker threads)
// ---------------------------------------------------------------------------

namespace {

std::string PackageJSONPath() {
    return ProfileDir() + "/package.json";
}

bool ReadPackageJSON(Json::Value* out) {
    std::string text = ReadFileText(PackageJSONPath());
    return !text.empty() && Json::Parse(text, out);
}

// Reads a package's manifest from the profile's node_modules. pnpm hoists
// dependencies to the top level, so a top-level lookup covers direct
// installs and hoisted transitive deps alike.
bool ReadNodeModulesPackage(const std::string& name, Json::Value* out) {
    std::string text = ReadFileText(ProfileDir() + "/node_modules/" + name + "/package.json");
    return !text.empty() && Json::Parse(text, out);
}

std::vector<std::string> StringArray(const Json::Value& v) {
    std::vector<std::string> out;
    if (!v.IsArray()) return out;
    for (size_t i = 0; i < v.Size(); ++i) {
        if (v.At(i).IsString()) out.push_back(v.At(i).AsString());
    }
    return out;
}

// Recursive dependency-tree builder (depth-limited, cycle-guarded).
void BuildNode(const std::string& name, int depth, std::set<std::string>* seen,
               std::vector<PluginNode>* out) {
    PluginNode node;
    node.name = name;
    if (depth >= 4 || !seen->insert(name).second) {
        out->push_back(std::move(node));
        return;
    }
    Json::Value manifest;
    if (ReadNodeModulesPackage(name, &manifest)) {
        if (const Json::Value* deps = manifest.Get("dependencies"); deps && deps->IsObject()) {
            for (const std::string& dep : deps->Keys()) {
                BuildNode(dep, depth + 1, seen, &node.children);
            }
        }
    }
    out->push_back(std::move(node));
}

// Tail of combined process output (pnpm prints a lot).
std::string OutputTail(const std::string& output) {
    std::vector<std::string> lines;
    size_t start = 0;
    while (start <= output.size()) {
        size_t nl = output.find('\n', start);
        if (nl == std::string::npos) {
            if (start < output.size()) lines.push_back(output.substr(start));
            break;
        }
        lines.push_back(output.substr(start, nl - start));
        start = nl + 1;
    }
    size_t from = lines.size() > 12 ? lines.size() - 12 : 0;
    std::string tail;
    for (size_t i = from; i < lines.size(); ++i) {
        if (!tail.empty()) tail += "\n";
        tail += lines[i];
    }
    return tail.empty() ? "exit non-zero" : tail;
}

} // namespace

std::string ProfileDir() {
    return std::string(g_get_home_dir()) + "/.dsh/profiles/web";
}

std::vector<std::string> InstalledPackages() {
    Json::Value root;
    if (!ReadPackageJSON(&root)) return {};
    if (const Json::Value* deps = root.Get("dependencies"); deps && deps->IsObject()) {
        return deps->Keys();
    }
    return {};
}

std::vector<std::string> EnabledBundles() {
    Json::Value root;
    if (!ReadPackageJSON(&root)) return {};
    if (const Json::Value* dsh = root.Get("dsh"); dsh && dsh->IsObject()) {
        if (const Json::Value* profile = dsh->Get("profile"); profile && profile->IsObject()) {
            if (const Json::Value* bundles = profile->Get("bundles")) {
                return StringArray(*bundles);
            }
        }
    }
    return {};
}

std::vector<PluginNode> DependencyTree() {
    std::vector<std::string> direct = InstalledPackages();
    std::set<std::string> directSet(direct.begin(), direct.end());
    std::vector<PluginNode> roots;
    for (const std::string& name : direct) {
        std::set<std::string> seen;
        BuildNode(name, 0, &seen, &roots);
    }
    for (const std::string& bundle : EnabledBundles()) {
        if (directSet.count(bundle) == 0) {
            PluginNode builtin;
            builtin.name = bundle;
            builtin.builtin = true;
            roots.push_back(std::move(builtin));
        }
    }
    return roots;
}

bool SetEnabled(const std::string& name, bool enabled, std::string* error) {
    Json::Value root;
    if (!ReadPackageJSON(&root)) {
        if (error) *error = "cannot read " + PackageJSONPath();
        return false;
    }
    Json::Value& dsh = root.GetOrCreate("dsh");
    Json::Value& profile = dsh.GetOrCreate("profile");
    Json::Value bundles = Json::Value::MakeArray();
    if (const Json::Value* existing = profile.Get("bundles"); existing && existing->IsArray()) {
        bundles = *existing;
    }
    if (enabled) {
        bool found = false;
        for (size_t i = 0; i < bundles.Size(); ++i) {
            if (bundles.At(i).IsString() && bundles.At(i).AsString() == name) { found = true; break; }
        }
        if (!found) bundles.Push(Json::Value::MakeString(name));
    } else {
        bundles.RemoveString(name);
    }
    profile.Set("bundles", std::move(bundles));
    if (!WriteFileText(PackageJSONPath(), Json::Stringify(root, true))) {
        if (error) *error = "cannot write " + PackageJSONPath();
        return false;
    }
    return true;
}

std::vector<MarketPlugin> FetchMarket() {
    std::vector<MarketPlugin> out;
    GError* err = nullptr;
    SoupSession* session = soup_session_new();
    SoupMessage* msg = soup_message_new(
        "GET", "https://tonytsangzen.github.io/harness-market/data.js");
    std::string text;
    if (msg) {
        GBytes* bytes = soup_session_send_and_read(session, msg, nullptr, &err);
        if (!err && bytes) {
            gsize len = 0;
            const gchar* data = static_cast<const gchar*>(g_bytes_get_data(bytes, &len));
            text.assign(data, len);
        }
        if (bytes) g_bytes_unref(bytes);
        g_object_unref(msg);
    }
    g_object_unref(session);
    if (err) g_error_free(err);
    if (text.empty()) return out;

    // data.js is `window.PLUGIN_DATA = {...};` — take the first '{' .. last '}'.
    size_t start = text.find('{');
    size_t end = text.rfind('}');
    if (start == std::string::npos || end == std::string::npos || start >= end) return out;
    Json::Value root;
    if (!Json::Parse(text.substr(start, end - start + 1), &root)) return out;

    const Json::Value* plugins = root.Get("plugins");
    if (!plugins || !plugins->IsArray()) return out;

    bool zh = SystemLanguageIsChinese();
    for (size_t i = 0; i < plugins->Size(); ++i) {
        const Json::Value& p = plugins->At(i);
        if (!p.IsObject()) continue;
        MarketPlugin mp;
        if (const Json::Value* v = p.Get("id"); v && v->IsString()) mp.id = v->AsString();
        if (const Json::Value* v = p.Get("name"); v && v->IsString()) mp.name = v->AsString();
        if (mp.name.empty()) continue;
        if (const Json::Value* v = p.Get("display_name"); v && v->IsString()) mp.displayName = v->AsString();
        if (mp.displayName.empty()) mp.displayName = mp.name;
        if (const Json::Value* v = p.Get("type"); v && v->IsString()) mp.type = v->AsString();
        if (const Json::Value* v = p.Get("category"); v && v->IsString()) mp.category = v->AsString();
        if (const Json::Value* v = p.Get("url"); v && v->IsString()) mp.url = v->AsString();
        if (const Json::Value* v = p.Get("version"); v && v->IsString()) mp.version = v->AsString();
        if (const Json::Value* v = p.Get("stars"); v && v->IsNumber()) {
            mp.hasStars = true;
            mp.stars = static_cast<int>(v->AsNumber());
        }
        const Json::Value* summary = zh ? p.Get("description_zh") : p.Get("description");
        if (!summary || !summary->IsString() || summary->AsString().empty()) summary = p.Get("description");
        if (summary && summary->IsString()) mp.summary = summary->AsString();
        out.push_back(std::move(mp));
    }
    return out;
}

std::string MarketPlugin::NpmPackage() const {
    if (type != "package") return {};
    if (!id.empty() && id.rfind("npm:", 0) == 0) return id.substr(4);
    return name;
}

std::string MarketPlugin::GitSpec() const {
    if (type == "package") return {};
    if (!id.empty() && id.rfind("gh:", 0) == 0) return "github:" + id.substr(3);
    // Fallback: derive owner/repo from the GitHub URL.
    size_t pos = url.find("github.com/");
    if (pos != std::string::npos) {
        std::string rest = url.substr(pos + 11);
        size_t slash = rest.find('/');
        if (slash != std::string::npos) return "github:" + rest.substr(0, slash) + "/" +
                                               rest.substr(slash + 1, rest.find('/', slash + 1) - slash - 1);
    }
    return {};
}

CommandResult RunDshPlugin(const std::vector<std::string>& args) {
    CommandResult result;
    std::vector<std::string> cmd;
    cmd.push_back("npx");
    cmd.push_back("--yes");
    cmd.push_back("@deepseek-ai/dsh");
    cmd.push_back("plugin");
    cmd.push_back("--profile");
    cmd.push_back("web");
    for (const std::string& a : args) cmd.push_back(a);

    std::vector<char*> argv;
    for (auto& c : cmd) argv.push_back(const_cast<char*>(c.c_str()));
    argv.push_back(nullptr);

    gchar* outBuf = nullptr;
    gchar* errBuf = nullptr;
    GError* error = nullptr;
    gint status = 0;
    bool ok = g_spawn_sync(ProfileDir().c_str(), argv.data(), nullptr, G_SPAWN_SEARCH_PATH,
                           nullptr, nullptr, &outBuf, &errBuf, &status, &error);
    std::string combined;
    if (outBuf) { combined += outBuf; g_free(outBuf); }
    if (errBuf) { combined += errBuf; g_free(errBuf); }
    if (error) {
        result.output = error->message ? error->message : "spawn failed";
        g_error_free(error);
        return result;
    }
    result.ok = ok && g_spawn_check_wait_status(status, nullptr);
    result.output = OutputTail(combined);
    return result;
}

bool PnpmAvailable() {
    std::vector<char*> argv{const_cast<char*>("which"), const_cast<char*>("pnpm"), nullptr};
    GError* error = nullptr;
    gint status = 0;
    bool ok = g_spawn_sync(nullptr, argv.data(), nullptr, G_SPAWN_SEARCH_PATH,
                           nullptr, nullptr, nullptr, nullptr, &status, &error);
    if (error) g_error_free(error);
    return ok && g_spawn_check_wait_status(status, nullptr);
}

// ---------------------------------------------------------------------------
// Dialog (main thread)
// ---------------------------------------------------------------------------

namespace {

// Column ids for the installed dependency-tree store.
enum InstalledCol { INST_NAME = 0, INST_STATUS = 1, INST_FLAGS = 2, INST_COLS };
// Row flags for the installed tree.
enum InstalledFlag { FLAG_ROOT = 0, FLAG_BUILTIN = 1, FLAG_DEP = 2 };

// Column ids for the enabled list store.
enum EnabledCol { EN_ORDER = 0, EN_NAME = 1, EN_COLS };

// Column ids for the market list store (last column holds the index into
// DialogState::market and is hidden).
enum MarketCol { MK_NAME = 0, MK_TYPE = 1, MK_CATEGORY = 2, MK_VERSION = 3,
                 MK_STARS = 4, MK_IDX = 5, MK_COLS };

// All mutable dialog state. Owned via `new`; the dialog sets `closed` before
// destroying itself and the last pending worker idle callback deletes the
// object (operations run strictly one at a time, so at most one worker is
// ever outstanding).
struct DialogState {
    GtkWidget* dlg = nullptr;
    GtkWidget* notebook = nullptr;
    GtkWidget* search = nullptr;
    GtkWidget* installedView = nullptr;
    GtkWidget* enabledView = nullptr;
    GtkWidget* marketView = nullptr;
    GtkWidget* statusLabel = nullptr;
    GtkWidget* installBtn = nullptr;
    GtkWidget* uninstallBtn = nullptr;
    GtkWidget* enableBtn = nullptr;
    GtkWidget* disableBtn = nullptr;
    GtkWidget* openBtn = nullptr;
    GtkWidget* restartBtn = nullptr;
    GtkWidget* refreshBtn = nullptr;
    GtkWidget* localFileBtn = nullptr;
    GtkWidget* localDirBtn = nullptr;
    bool zh = false;
    bool closed = false;
    bool busy = false;
    int pendingWorkers = 0; // outstanding worker idle callbacks that own `this`
    std::function<void()> onRestart;
    std::vector<MarketPlugin> market;
    std::vector<std::string> installed;
    std::vector<std::string> enabled;
};

const char* S(DialogState* s, const char* zh, const char* en) {
    return s->zh ? zh : en;
}

std::string Trim(const std::string& in) {
    size_t b = in.find_first_not_of(" \t\r\n");
    size_t e = in.find_last_not_of(" \t\r\n");
    return (b == std::string::npos) ? std::string() : in.substr(b, e - b + 1);
}

// ---- tree view population ---------------------------------------------------

GtkTreeStore* InstalledStore(DialogState* s) {
    return GTK_TREE_STORE(gtk_tree_view_get_model(GTK_TREE_VIEW(s->installedView)));
}

void FillInstalledRec(DialogState* s, GtkTreeStore* store, GtkTreeIter* parent,
                      const PluginNode& node, bool isRoot) {
    GtkTreeIter it;
    gtk_tree_store_append(store, &it, parent);
    int flag = isRoot ? (node.builtin ? FLAG_BUILTIN : FLAG_ROOT) : FLAG_DEP;
    std::string status;
    if (isRoot) {
        bool on = std::find(s->enabled.begin(), s->enabled.end(), node.name) != s->enabled.end();
        if (node.builtin) {
            status = S(s, "内置", "Built-in");
            if (on) status += S(s, " · 已启用", " · enabled");
        } else {
            status = on ? S(s, "已启用", "enabled") : S(s, "已停用", "disabled");
        }
    } else {
        status = S(s, "依赖", "dependency");
    }
    gtk_tree_store_set(store, &it, INST_NAME, node.name.c_str(),
                       INST_STATUS, status.c_str(), INST_FLAGS, flag, -1);
    for (const PluginNode& child : node.children) {
        FillInstalledRec(s, store, &it, child, false);
    }
}

void FillInstalled(DialogState* s) {
    GtkTreeStore* store = InstalledStore(s);
    gtk_tree_store_clear(store);
    std::vector<PluginNode> tree = DependencyTree();
    for (const PluginNode& root : tree) {
        FillInstalledRec(s, store, nullptr, root, true);
    }
    // Default: collapsed (only the directly installed roots are visible).
    gtk_tree_view_collapse_all(GTK_TREE_VIEW(s->installedView));
}

void FillEnabled(DialogState* s) {
    GtkListStore* store = GTK_LIST_STORE(gtk_tree_view_get_model(GTK_TREE_VIEW(s->enabledView)));
    gtk_list_store_clear(store);
    size_t order = 1;
    for (const std::string& name : s->enabled) {
        GtkTreeIter it;
        gtk_list_store_append(store, &it);
        gtk_list_store_set(store, &it, EN_ORDER, static_cast<guint>(order),
                           EN_NAME, name.c_str(), -1);
        ++order;
    }
}

void FillMarket(DialogState* s) {
    GtkListStore* store = GTK_LIST_STORE(gtk_tree_view_get_model(GTK_TREE_VIEW(s->marketView)));
    gtk_list_store_clear(store);
    std::string filter = Trim(gtk_entry_get_text(GTK_ENTRY(s->search)));
    for (size_t i = 0; i < s->market.size(); ++i) {
        const MarketPlugin& p = s->market[i];
        if (!filter.empty()) {
            bool hit = p.name.find(filter) != std::string::npos ||
                       p.displayName.find(filter) != std::string::npos ||
                       p.category.find(filter) != std::string::npos ||
                       p.summary.find(filter) != std::string::npos;
            if (!hit) continue;
        }
        GtkTreeIter it;
        gtk_list_store_append(store, &it);
        gtk_list_store_set(store, &it,
                           MK_NAME, p.displayName.c_str(),
                           MK_TYPE, (p.type == "package" ? S(s, "npm 包", "npm package")
                                                         : S(s, "仓库", "repo")),
                           MK_CATEGORY, p.category.c_str(),
                           MK_VERSION, p.version.c_str(),
                           MK_STARS, p.hasStars ? std::to_string(p.stars).c_str() : "",
                           MK_IDX, static_cast<guint>(i), -1);
    }
}

// Name column of the installed tree: roots bold, dependency rows dimmed.
void InstalledNameCell(GtkTreeViewColumn* /*col*/, GtkCellRenderer* renderer,
                       GtkTreeModel* model, GtkTreeIter* iter, gpointer /*data*/) {
    int flag = 0;
    gtk_tree_model_get(model, iter, INST_FLAGS, &flag, -1);
    if (flag == FLAG_DEP) {
        g_object_set(renderer, "weight", PANGO_WEIGHT_NORMAL,
                     "foreground-set", TRUE, "foreground", "#888888", NULL);
    } else {
        g_object_set(renderer, "weight", PANGO_WEIGHT_BOLD,
                     "foreground-set", FALSE, NULL);
    }
}

// ---- button enablement -------------------------------------------------------

std::string NameOfInstalledRow(GtkTreeModel* model, GtkTreeIter* iter) {
    gchar* name = nullptr;
    gtk_tree_model_get(model, iter, INST_NAME, &name, -1);
    std::string out = name ? name : "";
    g_free(name);
    return out;
}

void SetStatus(DialogState* s, const std::string& text) {
    gtk_label_set_text(GTK_LABEL(s->statusLabel), text.c_str());
}

void UpdateButtons(DialogState* s) {
    bool on = !s->busy;
    gtk_widget_set_sensitive(s->refreshBtn, on);
    gtk_widget_set_sensitive(s->localFileBtn, on);
    gtk_widget_set_sensitive(s->localDirBtn, on);
    gtk_widget_set_sensitive(s->restartBtn, on);

    int page = gtk_notebook_get_current_page(GTK_NOTEBOOK(s->notebook));
    bool canInstall = false, canUninstall = false, canEnable = false,
         canDisable = false, canOpen = false;

    if (on) {
        if (page == 0) {
            GtkTreeSelection* sel = gtk_tree_view_get_selection(GTK_TREE_VIEW(s->installedView));
            GtkTreeModel* model = nullptr;
            GtkTreeIter iter;
            if (gtk_tree_selection_get_selected(sel, &model, &iter)) {
                int flag = 0;
                gtk_tree_model_get(model, &iter, INST_FLAGS, &flag, -1);
                if (flag == FLAG_ROOT) {
                    bool isOn = std::find(s->enabled.begin(), s->enabled.end(),
                                          NameOfInstalledRow(model, &iter)) != s->enabled.end();
                    canEnable = !isOn;
                    canDisable = isOn;
                    canUninstall = true;
                }
            }
        } else if (page == 1) {
            GtkTreeSelection* sel = gtk_tree_view_get_selection(GTK_TREE_VIEW(s->enabledView));
            GtkTreeModel* model = nullptr;
            GtkTreeIter iter;
            if (gtk_tree_selection_get_selected(sel, &model, &iter)) {
                canDisable = true;
            }
        } else if (page == 2) {
            GtkTreeSelection* sel = gtk_tree_view_get_selection(GTK_TREE_VIEW(s->marketView));
            GtkTreeModel* model = nullptr;
            GtkTreeIter iter;
            if (gtk_tree_selection_get_selected(sel, &model, &iter)) {
                guint idx = 0;
                gtk_tree_model_get(model, &iter, MK_IDX, &idx, -1);
                if (idx < s->market.size()) {
                    const MarketPlugin& p = s->market[idx];
                    canInstall = !p.NpmPackage().empty() || !p.GitSpec().empty();
                    canOpen = !p.url.empty();
                }
            }
        }
    }

    gtk_widget_set_sensitive(s->installBtn, canInstall);
    gtk_widget_set_sensitive(s->uninstallBtn, canUninstall);
    gtk_widget_set_sensitive(s->enableBtn, canEnable);
    gtk_widget_set_sensitive(s->disableBtn, canDisable);
    gtk_widget_set_sensitive(s->openBtn, canOpen);
}

// ---- background operations ---------------------------------------------------

struct OpCtx {
    DialogState* state = nullptr;
    std::vector<std::string> args;
    std::string label; // e.g. "安装 xxx…"
    std::string spec;  // the package name / path the operation touched
    CommandResult result;
    bool pnpmRequired = true;
};

gpointer OpThread(gpointer data) {
    auto* ctx = static_cast<OpCtx*>(data);
    if (ctx->pnpmRequired && !PnpmAvailable()) {
        ctx->result.ok = false;
        ctx->result.output = ctx->state->zh
            ? "未找到 pnpm（安装插件需要它，请先安装 corepack/pnpm）"
            : "pnpm not found (required to install plugins; install corepack/pnpm first)";
    } else {
        ctx->result = RunDshPlugin(ctx->args);
    }
    g_idle_add([](gpointer d) -> gboolean {
        auto* ctx = static_cast<OpCtx*>(d);
        DialogState* s = ctx->state;
        if (!s->closed) {
            s->busy = false;
            // Refresh local state (deps / bundles) after any mutation.
            s->installed = InstalledPackages();
            s->enabled = EnabledBundles();
            FillInstalled(s);
            FillEnabled(s);
            UpdateButtons(s);
            if (ctx->result.ok) {
                std::string status = ctx->label + " — " +
                    (s->zh ? "完成" : "done");
                bool inBundles = std::find(s->enabled.begin(), s->enabled.end(),
                                           ctx->spec) != s->enabled.end();
                status += inBundles
                    ? " · " + std::string(s->zh ? "需重启 dsh web 生效" : "restart dsh web to apply")
                    : " · " + std::string(s->zh ? "无需重启（普通依赖）" : "no restart needed (plain dependency)");
                SetStatus(s, status);
            } else {
                SetStatus(s, ctx->label + ": " + ctx->result.output);
            }
        }
        delete ctx;
        bool last = --s->pendingWorkers == 0;
        if (s->closed && last) delete s;
        return G_SOURCE_REMOVE;
    }, ctx);
    return nullptr;
}

// Starts a background dsh plugin operation (busy-guarded).
void StartOp(DialogState* s, const std::vector<std::string>& args,
             const std::string& spec, const std::string& label,
             bool pnpmRequired) {
    if (s->busy || s->closed) return;
    s->busy = true;
    ++s->pendingWorkers;
    UpdateButtons(s);
    SetStatus(s, label + "…");
    auto* ctx = new OpCtx;
    ctx->state = s;
    ctx->args = args;
    ctx->spec = spec;
    ctx->label = label;
    ctx->pnpmRequired = pnpmRequired;
    g_thread_unref(g_thread_new("plugin-op", OpThread, ctx));
}

// ---- local state refresh ------------------------------------------------------

void RefreshLocalData(DialogState* s) {
    s->installed = InstalledPackages();
    s->enabled = EnabledBundles();
    FillInstalled(s);
    FillEnabled(s);
    UpdateButtons(s);
}

// ---- market loading (worker) ---------------------------------------------------

struct MarketCtx {
    DialogState* state = nullptr;
    std::vector<MarketPlugin> plugins;
};

gpointer MarketThread(gpointer data) {
    auto* ctx = static_cast<MarketCtx*>(data);
    ctx->plugins = FetchMarket();
    g_idle_add([](gpointer d) -> gboolean {
        auto* ctx = static_cast<MarketCtx*>(d);
        DialogState* s = ctx->state;
        if (!s->closed) {
            s->market = std::move(ctx->plugins);
            FillMarket(s);
            UpdateButtons(s);
            SetStatus(s, s->zh
                ? (s->market.empty() ? "插件市场加载失败" : "插件市场已加载（" +
                   std::to_string(s->market.size()) + " 个插件）")
                : (s->market.empty() ? "Failed to load the plugin market"
                                     : "Plugin market loaded (" + std::to_string(s->market.size()) + " plugins)"));
        }
        delete ctx;
        bool last = --s->pendingWorkers == 0;
        if (s->closed && last) delete s;
        return G_SOURCE_REMOVE;
    }, ctx);
    return nullptr;
}

void ReloadMarket(DialogState* s) {
    if (s->busy || s->closed) return;
    ++s->pendingWorkers;
    SetStatus(s, s->zh ? "正在加载插件市场…" : "Loading the plugin market…");
    auto* ctx = new MarketCtx;
    ctx->state = s;
    g_thread_unref(g_thread_new("market-fetch", MarketThread, ctx));
}

// ---- selection / action handlers ------------------------------------------------

void OnSelectionChanged(GtkTreeSelection* /*sel*/, gpointer userData) {
    UpdateButtons(static_cast<DialogState*>(userData));
}

void OnPageChanged(GtkNotebook* /*nb*/, GtkWidget* /*page*/, guint /*pageNum*/,
                   gpointer userData) {
    auto* s = static_cast<DialogState*>(userData);
    gtk_widget_set_sensitive(s->search,
                             gtk_notebook_get_current_page(GTK_NOTEBOOK(s->notebook)) == 2);
    UpdateButtons(s);
}

void OnSearchChanged(GtkSearchEntry* /*entry*/, gpointer userData) {
    FillMarket(static_cast<DialogState*>(userData));
}

void OnInstall(DialogState* s) {
    GtkTreeSelection* sel = gtk_tree_view_get_selection(GTK_TREE_VIEW(s->marketView));
    GtkTreeModel* model = nullptr;
    GtkTreeIter iter;
    if (!gtk_tree_selection_get_selected(sel, &model, &iter)) return;
    guint idx = 0;
    gtk_tree_model_get(model, &iter, MK_IDX, &idx, -1);
    if (idx >= s->market.size()) return;
    const MarketPlugin& p = s->market[idx];
    std::string spec = p.NpmPackage();
    if (spec.empty()) spec = p.GitSpec();
    if (spec.empty()) return;
    StartOp(s, {"add", spec}, spec,
            std::string(s->zh ? "安装 " : "Install ") + p.displayName, true);
}

void OnUninstall(DialogState* s) {
    GtkTreeSelection* sel = gtk_tree_view_get_selection(GTK_TREE_VIEW(s->installedView));
    GtkTreeModel* model = nullptr;
    GtkTreeIter iter;
    if (!gtk_tree_selection_get_selected(sel, &model, &iter)) return;
    int flag = 0;
    gtk_tree_model_get(model, &iter, INST_FLAGS, &flag, -1);
    if (flag != FLAG_ROOT) return;
    std::string name = NameOfInstalledRow(model, &iter);
    if (name.empty()) return;
    StartOp(s, {"remove", name}, name,
            std::string(s->zh ? "卸载 " : "Uninstall ") + name, false);
}

void OnEnableDisable(DialogState* s, bool enable) {
    std::string name;
    int page = gtk_notebook_get_current_page(GTK_NOTEBOOK(s->notebook));
    if (page == 0) {
        GtkTreeSelection* sel = gtk_tree_view_get_selection(GTK_TREE_VIEW(s->installedView));
        GtkTreeModel* model = nullptr;
        GtkTreeIter iter;
        if (!gtk_tree_selection_get_selected(sel, &model, &iter)) return;
        int flag = 0;
        gtk_tree_model_get(model, &iter, INST_FLAGS, &flag, -1);
        if (flag != FLAG_ROOT) return;
        name = NameOfInstalledRow(model, &iter);
    } else if (page == 1) {
        GtkTreeSelection* sel = gtk_tree_view_get_selection(GTK_TREE_VIEW(s->enabledView));
        GtkTreeModel* model = nullptr;
        GtkTreeIter iter;
        if (!gtk_tree_selection_get_selected(sel, &model, &iter)) return;
        gchar* n = nullptr;
        gtk_tree_model_get(model, &iter, EN_NAME, &n, -1);
        name = n ? n : "";
        g_free(n);
    } else {
        return;
    }
    if (name.empty()) return;
    std::string error;
    if (!SetEnabled(name, enable, &error)) {
        SetStatus(s, name + ": " + error);
        return;
    }
    RefreshLocalData(s);
    std::string status = name + " — " +
        (s->zh ? (enable ? "已启用" : "已停用") : (enable ? "enabled" : "disabled")) +
        " · " + (s->zh ? "需重启 dsh web 生效" : "restart dsh web to apply");
    SetStatus(s, status);
    gtk_widget_set_sensitive(s->restartBtn, TRUE);
}

void OnOpen(DialogState* s) {
    GtkTreeSelection* sel = gtk_tree_view_get_selection(GTK_TREE_VIEW(s->marketView));
    GtkTreeModel* model = nullptr;
    GtkTreeIter iter;
    if (!gtk_tree_selection_get_selected(sel, &model, &iter)) return;
    guint idx = 0;
    gtk_tree_model_get(model, &iter, MK_IDX, &idx, -1);
    if (idx >= s->market.size()) return;
    const std::string& url = s->market[idx].url;
    if (url.empty()) return;
    GError* error = nullptr;
    gtk_show_uri_on_window(GTK_WINDOW(s->dlg), url.c_str(), GDK_CURRENT_TIME, &error);
    if (error) g_error_free(error);
}

void OnRestart(DialogState* s) {
    if (s->onRestart) s->onRestart();
    SetStatus(s, s->zh ? "已请求重启 dsh web…" : "Restarting dsh web…");
    gtk_widget_set_sensitive(s->restartBtn, FALSE);
}

void OnRefresh(DialogState* s) {
    RefreshLocalData(s);
    ReloadMarket(s);
}

// ---- local package install ------------------------------------------------------

void OnLocalInstall(DialogState* s, bool pickDirectory) {
    if (s->busy || s->closed) return;
    const char* title = pickDirectory
        ? S(s, "选择插件目录（含 package.json）", "Choose a plugin directory (with package.json)")
        : S(s, "选择插件包文件（.tgz/.tar）", "Choose a plugin package file (.tgz/.tar)");
    GtkFileChooserNative* chooser = gtk_file_chooser_native_new(
        title, GTK_WINDOW(s->dlg),
        pickDirectory ? GTK_FILE_CHOOSER_ACTION_SELECT_FOLDER : GTK_FILE_CHOOSER_ACTION_OPEN,
        S(s, "安装", "Install"), S(s, "取消", "Cancel"));
    if (!pickDirectory) {
        GtkFileFilter* filter = gtk_file_filter_new();
        gtk_file_filter_set_name(filter, S(s, "插件包 (*.tgz, *.tar)", "Plugin package (*.tgz, *.tar)"));
        gtk_file_filter_add_pattern(filter, "*.tgz");
        gtk_file_filter_add_pattern(filter, "*.tar");
        gtk_file_chooser_add_filter(GTK_FILE_CHOOSER(chooser), filter);
    }
    gint response = gtk_native_dialog_run(GTK_NATIVE_DIALOG(chooser));
    gchar* path = nullptr;
    if (response == GTK_RESPONSE_ACCEPT) {
        path = gtk_file_chooser_get_filename(GTK_FILE_CHOOSER(chooser));
    }
    g_object_unref(chooser);
    if (!path) return;

    std::string p = path;
    g_free(path);
    if (pickDirectory) {
        if (!g_file_test((p + "/package.json").c_str(), G_FILE_TEST_IS_REGULAR)) {
            SetStatus(s, S(s, "所选目录中没有 package.json", "The selected directory has no package.json"));
            return;
        }
    }
    StartOp(s, {"add", p}, p,
            std::string(s->zh ? "安装 " : "Install ") + p, true);
}

// ---- button click glue -----------------------------------------------------------

void OnInstallClicked(GtkWidget* /*w*/, gpointer userData) { OnInstall(static_cast<DialogState*>(userData)); }
void OnUninstallClicked(GtkWidget* /*w*/, gpointer userData) { OnUninstall(static_cast<DialogState*>(userData)); }
void OnEnableClicked(GtkWidget* /*w*/, gpointer userData) { OnEnableDisable(static_cast<DialogState*>(userData), true); }
void OnDisableClicked(GtkWidget* /*w*/, gpointer userData) { OnEnableDisable(static_cast<DialogState*>(userData), false); }
void OnOpenClicked(GtkWidget* /*w*/, gpointer userData) { OnOpen(static_cast<DialogState*>(userData)); }
void OnRestartClicked(GtkWidget* /*w*/, gpointer userData) { OnRestart(static_cast<DialogState*>(userData)); }
void OnRefreshClicked(GtkWidget* /*w*/, gpointer userData) { OnRefresh(static_cast<DialogState*>(userData)); }
void OnLocalFileClicked(GtkWidget* /*w*/, gpointer userData) { OnLocalInstall(static_cast<DialogState*>(userData), false); }
void OnLocalDirClicked(GtkWidget* /*w*/, gpointer userData) { OnLocalInstall(static_cast<DialogState*>(userData), true); }

// ---- UI construction -------------------------------------------------------------

GtkWidget* BuildInstalledPage(DialogState* s) {
    GtkCellRendererText* renderer = gtk_cell_renderer_text_new();
    GtkTreeStore* store = gtk_tree_store_new(INST_COLS, G_TYPE_STRING, G_TYPE_STRING, G_TYPE_INT);
    GtkWidget* view = gtk_tree_view_new_with_model(GTK_TREE_MODEL(store));
    g_object_unref(store);
    gtk_tree_selection_set_mode(gtk_tree_view_get_selection(GTK_TREE_VIEW(view)), GTK_SELECTION_SINGLE);
    gtk_tree_view_set_headers_visible(GTK_TREE_VIEW(view), FALSE);

    GtkTreeViewColumn* nameCol = gtk_tree_view_column_new_with_attributes(
        "", renderer, "text", INST_NAME, nullptr);
    gtk_tree_view_column_set_expand(nameCol, TRUE);
    gtk_tree_view_column_set_cell_data_func(nameCol, renderer, InstalledNameCell, nullptr, nullptr);
    gtk_tree_view_append_column(GTK_TREE_VIEW(view), nameCol);

    GtkTreeViewColumn* statusCol = gtk_tree_view_column_new_with_attributes(
        "", renderer, "text", INST_STATUS, nullptr);
    gtk_tree_view_append_column(GTK_TREE_VIEW(view), statusCol);

    gtk_tree_view_set_show_expanders(GTK_TREE_VIEW(view), TRUE);
    g_signal_connect(gtk_tree_view_get_selection(GTK_TREE_VIEW(view)), "changed",
                     G_CALLBACK(OnSelectionChanged), s);
    s->installedView = view;
    return view;
}

GtkWidget* BuildEnabledPage(DialogState* s) {
    GtkCellRendererText* renderer = gtk_cell_renderer_text_new();
    GtkListStore* store = gtk_list_store_new(EN_COLS, G_TYPE_UINT, G_TYPE_STRING);
    GtkWidget* view = gtk_tree_view_new_with_model(GTK_TREE_MODEL(store));
    g_object_unref(store);
    gtk_tree_selection_set_mode(gtk_tree_view_get_selection(GTK_TREE_VIEW(view)), GTK_SELECTION_SINGLE);
    gtk_tree_view_set_headers_visible(GTK_TREE_VIEW(view), FALSE);
    gtk_tree_view_append_column(GTK_TREE_VIEW(view), gtk_tree_view_column_new_with_attributes(
        "", renderer, "text", EN_ORDER, nullptr));
    GtkTreeViewColumn* nameCol = gtk_tree_view_column_new_with_attributes(
        "", renderer, "text", EN_NAME, nullptr);
    gtk_tree_view_column_set_expand(nameCol, TRUE);
    gtk_tree_view_append_column(GTK_TREE_VIEW(view), nameCol);
    g_signal_connect(gtk_tree_view_get_selection(GTK_TREE_VIEW(view)), "changed",
                     G_CALLBACK(OnSelectionChanged), s);
    s->enabledView = view;
    return view;
}

GtkWidget* BuildMarketPage(DialogState* s) {
    GtkCellRendererText* renderer = gtk_cell_renderer_text_new();
    GtkListStore* store = gtk_list_store_new(MK_COLS, G_TYPE_STRING, G_TYPE_STRING,
                                             G_TYPE_STRING, G_TYPE_STRING,
                                             G_TYPE_STRING, G_TYPE_UINT);
    GtkWidget* view = gtk_tree_view_new_with_model(GTK_TREE_MODEL(store));
    g_object_unref(store);
    gtk_tree_selection_set_mode(gtk_tree_view_get_selection(GTK_TREE_VIEW(view)), GTK_SELECTION_SINGLE);
    gtk_tree_view_set_headers_visible(GTK_TREE_VIEW(view), TRUE);

    struct MkCol { const char* zh; const char* en; int col; bool expand; };
    const MkCol cols[] = {
        { "名称", "Name", MK_NAME, true },
        { "类型", "Type", MK_TYPE, false },
        { "分类", "Category", MK_CATEGORY, false },
        { "版本", "Version", MK_VERSION, false },
        { "星标", "Stars", MK_STARS, false },
    };
    for (const MkCol& c : cols) {
        GtkTreeViewColumn* col = gtk_tree_view_column_new_with_attributes(
            s->zh ? c.zh : c.en, renderer, "text", c.col, nullptr);
        if (c.expand) gtk_tree_view_column_set_expand(col, TRUE);
        gtk_tree_view_append_column(GTK_TREE_VIEW(view), col);
    }
    // The MK_IDX column stays in the model (selection reads it) but is hidden.
    GtkTreeViewColumn* hidden = gtk_tree_view_column_new_with_attributes(
        "", renderer, "text", MK_IDX, nullptr);
    gtk_tree_view_column_set_visible(hidden, FALSE);
    gtk_tree_view_append_column(GTK_TREE_VIEW(view), hidden);

    g_signal_connect(gtk_tree_view_get_selection(GTK_TREE_VIEW(view)), "changed",
                     G_CALLBACK(OnSelectionChanged), s);
    s->marketView = view;
    return view;
}

GtkWidget* MakeButton(const char* label, GCallback cb, DialogState* s, bool sensitive) {
    GtkWidget* b = gtk_button_new_with_label(label);
    g_signal_connect(b, "clicked", cb, s);
    gtk_widget_set_sensitive(b, sensitive);
    return b;
}

} // namespace

void ShowDialog(GtkWindow* parent, bool zh, const std::function<void()>& onRestart) {
    auto* s = new DialogState;
    s->zh = zh;
    s->onRestart = onRestart;

    s->dlg = gtk_dialog_new_with_buttons(
        zh ? "插件管理" : "Plugins", parent, GTK_DIALOG_MODAL,
        zh ? "关闭" : "Close", GTK_RESPONSE_CLOSE, nullptr);
    gtk_window_set_default_size(GTK_WINDOW(s->dlg), 780, 580);

    GtkWidget* content = gtk_dialog_get_content_area(GTK_DIALOG(s->dlg));
    GtkWidget* root = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8);
    gtk_container_set_border_width(GTK_CONTAINER(root), 12);
    gtk_box_pack_start(GTK_BOX(content), root, TRUE, TRUE, 0);

    // ---- top: notebook + search ----
    GtkWidget* topRow = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    gtk_box_pack_start(GTK_BOX(root), topRow, FALSE, FALSE, 0);

    s->notebook = gtk_notebook_new();
    gtk_box_pack_start(GTK_BOX(topRow), s->notebook, TRUE, TRUE, 0);

    s->search = gtk_search_entry_new();
    gtk_entry_set_placeholder_text(GTK_ENTRY(s->search),
                                   zh ? "搜索插件…" : "Search plugins…");
    gtk_widget_set_sensitive(s->search, FALSE);
    gtk_widget_set_size_request(s->search, 200, -1);
    gtk_box_pack_start(GTK_BOX(topRow), s->search, FALSE, FALSE, 0);
    g_signal_connect(s->search, "search-changed", G_CALLBACK(OnSearchChanged), s);

    GtkWidget* installedPage = BuildInstalledPage(s);
    GtkWidget* enabledPage = BuildEnabledPage(s);
    GtkWidget* marketPage = BuildMarketPage(s);
    gtk_notebook_append_page(GTK_NOTEBOOK(s->notebook), installedPage,
                             gtk_label_new(zh ? "已安装" : "Installed"));
    gtk_notebook_append_page(GTK_NOTEBOOK(s->notebook), enabledPage,
                             gtk_label_new(zh ? "已启用" : "Enabled"));
    gtk_notebook_append_page(GTK_NOTEBOOK(s->notebook), marketPage,
                             gtk_label_new(zh ? "插件市场" : "Market"));
    g_signal_connect(s->notebook, "switch-page", G_CALLBACK(OnPageChanged), s);

    // ---- status + buttons ----
    GtkWidget* bottomRow = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    gtk_box_pack_start(GTK_BOX(root), bottomRow, FALSE, FALSE, 0);

    s->statusLabel = gtk_label_new("");
    gtk_label_set_xalign(GTK_LABEL(s->statusLabel), 0);
    gtk_label_set_line_wrap(GTK_LABEL(s->statusLabel), TRUE);
    gtk_widget_set_size_request(s->statusLabel, 360, -1);
    gtk_box_pack_start(GTK_BOX(bottomRow), s->statusLabel, TRUE, TRUE, 0);

    s->localFileBtn = MakeButton(zh ? "从本地文件安装…" : "Install from File…",
                                 G_CALLBACK(OnLocalFileClicked), s, true);
    s->localDirBtn = MakeButton(zh ? "从本地目录安装…" : "Install from Folder…",
                                G_CALLBACK(OnLocalDirClicked), s, true);
    s->installBtn = MakeButton(zh ? "安装" : "Install", G_CALLBACK(OnInstallClicked), s, false);
    s->uninstallBtn = MakeButton(zh ? "卸载" : "Uninstall", G_CALLBACK(OnUninstallClicked), s, false);
    s->enableBtn = MakeButton(zh ? "启用" : "Enable", G_CALLBACK(OnEnableClicked), s, false);
    s->disableBtn = MakeButton(zh ? "停用" : "Disable", G_CALLBACK(OnDisableClicked), s, false);
    s->openBtn = MakeButton(zh ? "打开" : "Open", G_CALLBACK(OnOpenClicked), s, false);
    s->restartBtn = MakeButton(zh ? "重启 dsh web" : "Restart dsh web",
                               G_CALLBACK(OnRestartClicked), s, false);
    s->refreshBtn = MakeButton(zh ? "刷新" : "Refresh", G_CALLBACK(OnRefreshClicked), s, true);
    for (GtkWidget* b : { s->localFileBtn, s->localDirBtn, s->installBtn, s->uninstallBtn,
                          s->enableBtn, s->disableBtn, s->openBtn, s->restartBtn, s->refreshBtn }) {
        gtk_box_pack_start(GTK_BOX(bottomRow), b, FALSE, FALSE, 0);
    }

    gtk_widget_show_all(content);
    RefreshLocalData(s);
    ReloadMarket(s);

    gtk_dialog_run(GTK_DIALOG(s->dlg));
    s->closed = true;
    gtk_widget_destroy(s->dlg);
    // `s` is released here when no worker is outstanding; otherwise the last
    // pending worker idle callback releases it.
    if (s->pendingWorkers == 0) delete s;
}

} // namespace PluginsManager
} // namespace dsh
