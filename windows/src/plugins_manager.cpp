#include "plugins_manager.h"

#include "http.h"
#include "json.h"
#include "main_window.h"
#include "node_runtime_manager.h"
#include "util.h"

#include <winsock2.h>
#include <windows.h>
#include <commctrl.h>
#include <shlobj.h>
#include <shobjidl.h>
#include <shellapi.h>

#include <wrl/client.h>

#include <algorithm>
#include <cctype>
#include <cwctype>
#include <string>
#include <vector>

namespace dsh {
namespace PluginsManager {

namespace {

// ---- UTF-8 <-> UTF-16 ----

std::wstring Utf8ToWide(const std::string& s) {
    if (s.empty()) return L"";
    int len = MultiByteToWideChar(CP_UTF8, 0, s.c_str(), (int)s.size(), nullptr, 0);
    if (len <= 0) return L"";
    std::wstring out(len, L'\0');
    MultiByteToWideChar(CP_UTF8, 0, s.c_str(), (int)s.size(), out.data(), len);
    return out;
}

std::string WideToUtf8(const std::wstring& w) {
    if (w.empty()) return {};
    int len = WideCharToMultiByte(CP_UTF8, 0, w.c_str(), (int)w.size(), nullptr, 0, nullptr, nullptr);
    if (len <= 0) return {};
    std::string out(len, '\0');
    WideCharToMultiByte(CP_UTF8, 0, w.c_str(), (int)w.size(), out.data(), len, nullptr, nullptr);
    return out;
}

std::wstring ToLower(const std::wstring& s) {
    std::wstring out = s;
    std::transform(out.begin(), out.end(), out.begin(),
                   [](wchar_t c) { return static_cast<wchar_t>(std::towlower(c)); });
    return out;
}

// ---- localized strings ----

struct Strings {
    std::wstring title, tabInstalled, tabEnabled, tabMarket;
    std::wstring searchPlaceholder, refresh, install, uninstall, enable, disable, open;
    std::wstring loading, loadFailed, emptyInstalled, emptyEnabled, emptyMarket;
    std::wstring enabled, disabled, builtin, dependency, notInstalled;
    std::wstring restartHint, restartNow, doneInstall, doneUninstall, pnpmMissing;
    std::wstring localFile, localDir, close, selectFile, selectDir;
    std::wstring badDir, badFile, tgzFilterName;
    std::wstring colName, colType, colCategory, colVersion, colStars, colIndex;
    std::wstring noSelection, notInstallable, installing, opFailed, cannotUninstallBuiltin;
    std::wstring marketFailed, npmPackage, repo;
};

Strings Str(bool zh) {
    Strings s;
    if (zh) {
        s.title = L"插件管理";
        s.tabInstalled = L"已安装"; s.tabEnabled = L"已启用"; s.tabMarket = L"插件市场";
        s.searchPlaceholder = L"搜索插件…"; s.refresh = L"刷新";
        s.install = L"安装"; s.uninstall = L"卸载"; s.enable = L"启用"; s.disable = L"停用"; s.open = L"打开";
        s.loading = L"正在加载…"; s.loadFailed = L"加载失败";
        s.emptyInstalled = L"尚未安装任何插件"; s.emptyEnabled = L"没有已启用的插件"; s.emptyMarket = L"没有匹配的插件";
        s.enabled = L"已启用"; s.disabled = L"已停用"; s.builtin = L"内置"; s.dependency = L"依赖"; s.notInstalled = L"未安装";
        s.restartHint = L"插件层变更需重启 dsh web 生效"; s.restartNow = L"重启 dsh web";
        s.doneInstall = L"安装完成"; s.doneUninstall = L"卸载完成";
        s.pnpmMissing = L"未找到 pnpm（安装插件需要它，请先安装 corepack/pnpm）";
        s.localFile = L"从本地文件安装…"; s.localDir = L"从本地目录安装…"; s.close = L"关闭";
        s.selectFile = L"选择插件包文件（.tgz/.tar/.gz）"; s.selectDir = L"选择插件目录（含 package.json）";
        s.badDir = L"所选目录中没有 package.json"; s.badFile = L"不支持的包文件（支持 .tgz/.tar/.gz）";
        s.tgzFilterName = L"插件包文件";
        s.colName = L"名称"; s.colType = L"类型"; s.colCategory = L"分类"; s.colVersion = L"版本"; s.colStars = L"星标";
        s.colIndex = L"序号";
        s.noSelection = L"请先在列表中选择一项"; s.notInstallable = L"该条目不可直接安装";
        s.installing = L"安装"; s.opFailed = L"操作失败"; s.cannotUninstallBuiltin = L"内置插件不可卸载";
        s.marketFailed = L"市场加载失败"; s.npmPackage = L"npm 包"; s.repo = L"GitHub 仓库";
    } else {
        s.title = L"Plugins";
        s.tabInstalled = L"Installed"; s.tabEnabled = L"Enabled"; s.tabMarket = L"Market";
        s.searchPlaceholder = L"Search plugins…"; s.refresh = L"Refresh";
        s.install = L"Install"; s.uninstall = L"Uninstall"; s.enable = L"Enable"; s.disable = L"Disable"; s.open = L"Open";
        s.loading = L"Loading…"; s.loadFailed = L"Failed to load";
        s.emptyInstalled = L"No plugins installed yet"; s.emptyEnabled = L"No enabled plugins"; s.emptyMarket = L"No matching plugins";
        s.enabled = L"Enabled"; s.disabled = L"Disabled"; s.builtin = L"Built-in"; s.dependency = L"Dependency"; s.notInstalled = L"Not installed";
        s.restartHint = L"Plugin layer changes need a dsh web restart to take effect"; s.restartNow = L"Restart dsh web";
        s.doneInstall = L"Installed"; s.doneUninstall = L"Uninstalled";
        s.pnpmMissing = L"pnpm not found (required to install plugins; install corepack/pnpm first)";
        s.localFile = L"Install from File…"; s.localDir = L"Install from Folder…"; s.close = L"Close";
        s.selectFile = L"Choose a plugin package (.tgz/.tar/.gz)"; s.selectDir = L"Choose a plugin folder (with package.json)";
        s.badDir = L"The selected folder has no package.json"; s.badFile = L"Unsupported package file (use .tgz/.tar/.gz)";
        s.tgzFilterName = L"Plugin packages";
        s.colName = L"Name"; s.colType = L"Type"; s.colCategory = L"Category"; s.colVersion = L"Version"; s.colStars = L"Stars";
        s.colIndex = L"#";
        s.noSelection = L"Select an item first"; s.notInstallable = L"This entry cannot be installed directly";
        s.installing = L"Installing"; s.opFailed = L"Operation failed"; s.cannotUninstallBuiltin = L"Built-in plugins cannot be uninstalled";
        s.marketFailed = L"Market load failed"; s.npmPackage = L"npm package"; s.repo = L"GitHub repo";
    }
    return s;
}

const wchar_t* kMarketUrl = L"https://tonytsangzen.github.io/harness-market/data.js";

// ---- control ids / custom messages ----

constexpr int kIdcTab = 200;
constexpr int kIdcSearch = 201;
constexpr int kIdcInstalledTree = 202;
constexpr int kIdcEnabledList = 203;
constexpr int kIdcMarketList = 204;
constexpr int kIdcStatus = 205;
constexpr int kIdcBtnLocalFile = 206;
constexpr int kIdcBtnLocalDir = 207;
constexpr int kIdcBtnInstall = 208;
constexpr int kIdcBtnUninstall = 209;
constexpr int kIdcBtnEnable = 210;
constexpr int kIdcBtnDisable = 211;
constexpr int kIdcBtnOpen = 212;
constexpr int kIdcBtnRefresh = 213;
constexpr int kIdcBtnRestart = 214;

const UINT kPmMarketDone = WM_APP + 300;
const UINT kPmPluginDone = WM_APP + 301;

// ---- in-memory dialog template builder (same scheme as MainWindow) ----

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

// ---- dialog state ----

struct MarketResult {
    std::vector<MarketPlugin> plugins;
    std::wstring error;
};

struct DialogState {
    Strings s;
    HWND hDlg = nullptr;
    HWND tab = nullptr;
    HWND search = nullptr;
    HWND installedTree = nullptr;
    HWND enabledList = nullptr;
    HWND marketList = nullptr;
    HWND status = nullptr;

    std::vector<MarketPlugin> market;
    std::vector<std::wstring> installed;
    std::vector<std::wstring> enabled;
    std::vector<PluginNode> tree;
    std::wstring searchText;

    int currentTab = 0;
    bool busy = false;
    bool marketLoaded = false;
};

struct PluginCmdCtx {
    HWND hDlg;
    std::vector<std::wstring> args;
};

struct MarketCtx {
    HWND hDlg;
    bool zh;
};

// ---- misc UI helpers ----

HWND MakeCtrl(HWND parent, const wchar_t* cls, int id, const wchar_t* text,
              DWORD style, int x, int y, int cx, int cy) {
    return CreateWindowExW(0, cls, text, style | WS_CHILD | WS_VISIBLE,
                           x, y, cx, cy, parent, reinterpret_cast<HMENU>(static_cast<INT_PTR>(id)),
                           GetModuleHandleW(nullptr), nullptr);
}

void ApplyFont(HWND ctrl, HWND hDlg) {
    HFONT f = reinterpret_cast<HFONT>(SendMessageW(hDlg, WM_GETFONT, 0, 0));
    if (f) SendMessageW(ctrl, WM_SETFONT, reinterpret_cast<WPARAM>(f), TRUE);
}

void SetStatus(DialogState* st, const std::wstring& text) {
    if (st && st->status) SetWindowTextW(st->status, text.c_str());
}

std::string ReadUtf8File(const std::wstring& path) {
    std::string out;
    ReadFileBytes(path, out);
    return out;
}

// ---- data layer ----

void BuildNode(const std::wstring& name, int depth, std::vector<std::string>& visited,
               PluginNode& out) {
    if (depth >= 4) return;
    std::string key = WideToUtf8(name);
    if (std::find(visited.begin(), visited.end(), key) != visited.end()) return;
    visited.push_back(key);
    std::wstring manifest = JoinPath(JoinPath(JoinPath(ProfileDir(), L"node_modules"), name),
                                     L"package.json");
    std::string json = ReadUtf8File(manifest);
    if (json.empty()) return;
    size_t ds, de;
    if (!JsonGetValueRange(json, "dependencies", ds, de)) return;
    std::vector<std::string> keys;
    JsonObjectKeys(json, ds, de, keys);
    for (auto& k : keys) {
        PluginNode child;
        child.name = Utf8ToWide(k);
        BuildNode(child.name, depth + 1, visited, child);
        out.children.push_back(std::move(child));
    }
}

} // namespace

// ---- public data layer ----

std::wstring ProfileDir() {
    return JoinPath(GetUserProfile(), L".dsh\\profiles\\web");
}

std::vector<std::wstring> InstalledPackages() {
    std::vector<std::wstring> out;
    std::string json = ReadUtf8File(JoinPath(ProfileDir(), L"package.json"));
    if (json.empty()) return out;
    size_t ds, de;
    if (!JsonGetValueRange(json, "dependencies", ds, de)) return out;
    std::vector<std::string> keys;
    JsonObjectKeys(json, ds, de, keys);
    for (auto& k : keys) out.push_back(Utf8ToWide(k));
    return out;
}

std::vector<std::wstring> EnabledBundles() {
    std::vector<std::wstring> out;
    std::string json = ReadUtf8File(JoinPath(ProfileDir(), L"package.json"));
    if (json.empty()) return out;
    size_t ds, de, ps, pe, bs, be;
    if (!JsonGetValueRange(json, "dsh", ds, de)) return out;
    if (!JsonGetValueRangeAt(json, ds, de, "profile", ps, pe)) return out;
    if (!JsonGetValueRangeAt(json, ps, pe, "bundles", bs, be)) return out;
    std::vector<std::string> bundles;
    if (!JsonObjectGetStringArray(json, ps, pe, "bundles", bundles)) return out;
    for (auto& b : bundles) out.push_back(Utf8ToWide(b));
    (void)bs; (void)be;
    return out;
}

std::vector<PluginNode> DependencyTree() {
    std::vector<PluginNode> roots;
    auto direct = InstalledPackages();
    auto enabled = EnabledBundles();
    for (auto& n : direct) {
        PluginNode root;
        root.name = n;
        std::vector<std::string> visited;
        BuildNode(root.name, 0, visited, root);
        roots.push_back(std::move(root));
    }
    for (auto& b : enabled) {
        if (std::find(direct.begin(), direct.end(), b) == direct.end()) {
            PluginNode root;
            root.name = b;
            root.builtin = true;
            roots.push_back(std::move(root));
        }
    }
    return roots;
}

bool SetEnabled(const std::wstring& name, bool enable, std::wstring& error) {
    std::wstring path = JoinPath(ProfileDir(), L"package.json");
    std::string json = ReadUtf8File(path);
    if (json.empty()) {
        error = L"cannot read " + path;
        return false;
    }
    size_t ds, de, ps, pe;
    if (!JsonGetValueRange(json, "dsh", ds, de) ||
        !JsonGetValueRangeAt(json, ds, de, "profile", ps, pe)) {
        error = L"profile has no dsh.profile section";
        return false;
    }
    std::vector<std::string> cur;
    JsonObjectGetStringArray(json, ps, pe, "bundles", cur);
    std::string wname = WideToUtf8(name);
    auto it = std::find(cur.begin(), cur.end(), wname);
    if (enable && it == cur.end()) {
        cur.push_back(wname);
    } else if (!enable && it != cur.end()) {
        cur.erase(it);
    } else {
        return true; // no change
    }
    std::string updated;
    if (!JsonReplaceStringArray(json, ps, pe, "bundles", cur, updated)) {
        error = L"cannot update dsh.profile.bundles";
        return false;
    }
    // Write via Win32 (std::ofstream takes no wchar_t path on libstdc++).
    HANDLE h = CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS,
                           FILE_ATTRIBUTE_NORMAL, nullptr);
    if (h == INVALID_HANDLE_VALUE) {
        error = L"cannot write " + path;
        return false;
    }
    DWORD written = 0;
    WriteFile(h, updated.data(), static_cast<DWORD>(updated.size()), &written, nullptr);
    CloseHandle(h);
    return true;
}

bool PnpmAvailable() {
    std::wstring cmd = L"/c \"where pnpm >nul 2>&1\"";
    STARTUPINFOW si{};
    si.cb = sizeof(si);
    PROCESS_INFORMATION pi{};
    if (!CreateProcessW(L"cmd.exe", &cmd[0], nullptr, nullptr, FALSE,
                        CREATE_NO_WINDOW, nullptr, nullptr, &si, &pi)) {
        return false;
    }
    CloseHandle(pi.hThread);
    WaitForSingleObject(pi.hProcess, 15000);
    DWORD code = 0;
    GetExitCodeProcess(pi.hProcess, &code);
    CloseHandle(pi.hProcess);
    return code == 0;
}

std::vector<MarketPlugin> FetchMarket(bool zh, std::wstring& error) {
    std::vector<MarketPlugin> out;
    std::string body;
    if (!HttpGetString(kMarketUrl, body)) {
        error = L"network error";
        return out;
    }
    auto first = body.find('{');
    auto last = body.rfind('}');
    if (first == std::string::npos || last == std::string::npos || last <= first) {
        error = L"market index parse error";
        return out;
    }
    std::string json = body.substr(first, last - first + 1);
    size_t ps, pe;
    if (!JsonGetValueRange(json, "plugins", ps, pe)) {
        error = L"market index parse error";
        return out;
    }
    size_t pos = ps;
    size_t os, oe;
    while (JsonArrayNextObject(json, pos, os, oe)) {
        std::string s;
        MarketPlugin p;
        if (JsonObjectGetString(json, os, oe, "id", s)) p.id = Utf8ToWide(s);
        if (JsonObjectGetString(json, os, oe, "name", s)) p.name = Utf8ToWide(s);
        if (JsonObjectGetString(json, os, oe, "display_name", s)) p.displayName = Utf8ToWide(s);
        if (JsonObjectGetString(json, os, oe, "type", s)) p.type = Utf8ToWide(s);
        if (JsonObjectGetString(json, os, oe, "category", s)) p.category = Utf8ToWide(s);
        if (JsonObjectGetString(json, os, oe, "url", s)) p.url = Utf8ToWide(s);
        if (JsonObjectGetString(json, os, oe, "version", s)) p.version = Utf8ToWide(s);
        std::string desc;
        if (zh) JsonObjectGetString(json, os, oe, "description_zh", desc);
        if (desc.empty()) JsonObjectGetString(json, os, oe, "description", desc);
        p.summary = Utf8ToWide(desc);
        size_t vs, ve;
        if (JsonGetValueRangeAt(json, os, oe, "stars", vs, ve) && ve > vs) {
            std::string num = json.substr(vs, ve - vs);
            size_t b = num.find_first_not_of(" \t\r\n");
            size_t e = num.find_last_not_of(" \t\r\n");
            if (b != std::string::npos) num = num.substr(b, e - b + 1);
            try {
                p.stars = std::stoi(num);
                p.hasStars = true;
            } catch (...) {}
        }
        if (p.type == L"package") {
            if (p.id.rfind(L"npm:", 0) == 0) p.installSpec = p.id.substr(4);
            else p.installSpec = p.name;
        } else if (p.type == L"repo") {
            if (p.id.rfind(L"gh:", 0) == 0) p.installSpec = L"github:" + p.id.substr(3);
            else if (!p.name.empty()) p.installSpec = L"github:" + p.name;
        }
        if (p.name.empty() && p.installSpec.empty()) continue;
        out.push_back(std::move(p));
    }
    return out;
}

bool RunDshPlugin(const std::vector<std::wstring>& args, std::wstring& output) {
    std::wstring npx = NodeRuntimeManager::NpxPath();
    if (npx.empty()) npx = L"npx";
    std::wstring cmd = L"/c \"" + QuoteArg(npx);
    cmd += L" --yes @deepseek-ai/dsh plugin --profile web";
    for (auto& a : args) cmd += L" " + QuoteArg(a);
    cmd += L"\"";

    SECURITY_ATTRIBUTES sa{};
    sa.nLength = sizeof(sa);
    sa.bInheritHandle = TRUE;
    HANDLE outRead = nullptr, outWrite = nullptr;
    if (!CreatePipe(&outRead, &outWrite, &sa, 0)) {
        output = L"pipe error";
        return false;
    }
    SetHandleInformation(outRead, HANDLE_FLAG_INHERIT, 0);

    STARTUPINFOW si{};
    si.cb = sizeof(si);
    si.dwFlags = STARTF_USESTDHANDLES;
    si.hStdOutput = outWrite;
    si.hStdError = outWrite;
    si.hStdInput = GetStdHandle(STD_INPUT_HANDLE);
    PROCESS_INFORMATION pi{};
    std::wstring cwd = ProfileDir();
    bool created = CreateProcessW(L"cmd.exe", &cmd[0], nullptr, nullptr, TRUE,
                                  CREATE_NO_WINDOW, nullptr, cwd.c_str(), &si, &pi);
    CloseHandle(outWrite);
    if (!created) {
        CloseHandle(outRead);
        output = L"failed to start npx";
        return false;
    }
    CloseHandle(pi.hThread);

    std::string acc;
    char buf[4096];
    DWORD got = 0;
    for (;;) {
        if (!ReadFile(outRead, buf, sizeof(buf), &got, nullptr) || got == 0) break;
        acc.append(buf, got);
    }
    CloseHandle(outRead);
    WaitForSingleObject(pi.hProcess, 5 * 60 * 1000);
    DWORD code = 0;
    GetExitCodeProcess(pi.hProcess, &code);
    CloseHandle(pi.hProcess);

    // Keep only the meaningful tail (pnpm prints a lot).
    std::vector<std::string> lines;
    std::string cur;
    for (char c : acc) {
        if (c == '\n') { lines.push_back(cur); cur.clear(); }
        else if (c != '\r') cur += c;
    }
    if (!cur.empty()) lines.push_back(cur);
    size_t start = lines.size() > 12 ? lines.size() - 12 : 0;
    std::string tail;
    for (size_t i = start; i < lines.size(); i++) {
        if (i > start) tail += "\n";
        tail += lines[i];
    }
    output = Utf8ToWide(tail);
    if (output.empty()) output = L"exit " + std::to_wstring(code);
    return code == 0;
}

namespace {

// ---- worker threads ----

DWORD WINAPI MarketLoadThread(LPVOID p) {
    auto* ctx = static_cast<MarketCtx*>(p);
    auto* res = new MarketResult();
    res->plugins = FetchMarket(ctx->zh, res->error);
    PostMessageW(ctx->hDlg, kPmMarketDone, 0, reinterpret_cast<LPARAM>(res));
    delete ctx;
    return 0;
}

DWORD WINAPI PluginCmdThread(LPVOID p) {
    auto* ctx = static_cast<PluginCmdCtx*>(p);
    std::wstring output;
    bool ok = RunDshPlugin(ctx->args, output);
    PostMessageW(ctx->hDlg, kPmPluginDone, ok ? 1 : 0,
                 reinterpret_cast<LPARAM>(new std::wstring(output)));
    delete ctx;
    return 0;
}

// ---- list filling ----

void EnsureColumns(HWND list, const std::vector<std::wstring>& headers,
                   const std::vector<int>& widths) {
    LVCOLUMNW col{};
    if (SendMessageW(list, LVM_GETCOLUMN, 0, reinterpret_cast<LPARAM>(&col))) return;
    for (size_t i = 0; i < headers.size() && i < widths.size(); i++) {
        LVCOLUMNW c{};
        c.mask = LVCF_TEXT | LVCF_WIDTH | LVCF_SUBITEM;
        c.cx = widths[i];
        c.iSubItem = static_cast<int>(i);
        c.pszText = const_cast<wchar_t*>(headers[i].c_str());
        SendMessageW(list, LVM_INSERTCOLUMNW, i, reinterpret_cast<LPARAM>(&c));
    }
}

void SetSubItem(HWND list, int row, int col, const std::wstring& text) {
    LVITEMW it{};
    it.mask = LVIF_TEXT;
    it.iItem = row;
    it.iSubItem = col;
    it.pszText = const_cast<wchar_t*>(text.c_str());
    SendMessageW(list, LVM_SETITEMTEXTW, row, reinterpret_cast<LPARAM>(&it));
}

void InsertTreeNodes(DialogState* st, HTREEITEM parent, const PluginNode& node, int depth) {
    TVINSERTSTRUCTW ins{};
    ins.hParent = parent;
    ins.hInsertAfter = TVI_LAST;
    ins.item.mask = TVIF_TEXT | TVIF_PARAM;
    ins.item.lParam = reinterpret_cast<LPARAM>(&node);
    std::wstring label = node.name;
    if (node.builtin) {
        label += L"  (" + st->s.builtin + L")";
    } else if (depth > 0) {
        label = L"⤷ " + label;
    }
    ins.item.pszText = const_cast<wchar_t*>(label.c_str());
    HTREEITEM h = reinterpret_cast<HTREEITEM>(
        SendMessageW(st->installedTree, TVM_INSERTITEMW, 0, reinterpret_cast<LPARAM>(&ins)));
    for (auto& c : node.children) InsertTreeNodes(st, h, c, depth + 1);
}

void FillInstalledTree(DialogState* st) {
    SendMessageW(st->installedTree, TVM_DELETEITEM, 0, reinterpret_cast<LPARAM>(TVI_ROOT));
    for (auto& root : st->tree) InsertTreeNodes(st, TVI_ROOT, root, 0);
    if (st->tree.empty()) SetStatus(st, st->s.emptyInstalled);
}

void FillEnabledList(DialogState* st) {
    EnsureColumns(st->enabledList, {st->s.colIndex, st->s.colName}, {48, 420});
    SendMessageW(st->enabledList, LVM_DELETEALLITEMS, 0, 0);
    for (size_t i = 0; i < st->enabled.size(); i++) {
        LVITEMW it{};
        it.mask = LVIF_TEXT;
        it.iItem = static_cast<int>(i);
        it.iSubItem = 0;
        std::wstring idx = std::to_wstring(i + 1);
        it.pszText = const_cast<wchar_t*>(idx.c_str());
        SendMessageW(st->enabledList, LVM_INSERTITEMW, 0, reinterpret_cast<LPARAM>(&it));
        SetSubItem(st->enabledList, static_cast<int>(i), 1, st->enabled[i]);
    }
    if (st->enabled.empty()) SetStatus(st, st->s.emptyEnabled);
}

bool MarketMatches(const MarketPlugin& p, const std::wstring& q) {
    if (q.empty()) return true;
    return ToLower(p.name).find(q) != std::wstring::npos ||
           ToLower(p.displayName).find(q) != std::wstring::npos ||
           ToLower(p.category).find(q) != std::wstring::npos ||
           ToLower(p.summary).find(q) != std::wstring::npos;
}

void FillMarketList(DialogState* st) {
    EnsureColumns(st->marketList,
                  {st->s.colName, st->s.colType, st->s.colCategory, st->s.colVersion, st->s.colStars},
                  {240, 80, 90, 60, 60});
    SendMessageW(st->marketList, LVM_DELETEALLITEMS, 0, 0);
    std::wstring q = ToLower(st->searchText);
    int row = 0;
    for (size_t idx = 0; idx < st->market.size(); idx++) {
        auto& p = st->market[idx];
        if (!MarketMatches(p, q)) continue;
        LVITEMW it{};
        it.mask = LVIF_TEXT | LVIF_PARAM;
        it.iItem = row;
        it.iSubItem = 0;
        it.pszText = const_cast<wchar_t*>(p.displayName.c_str());
        it.lParam = static_cast<LPARAM>(idx); // index into st->market
        SendMessageW(st->marketList, LVM_INSERTITEMW, 0, reinterpret_cast<LPARAM>(&it));
        SetSubItem(st->marketList, row, 1, p.type == L"package" ? st->s.npmPackage : st->s.repo);
        SetSubItem(st->marketList, row, 2, p.category);
        SetSubItem(st->marketList, row, 3, p.version);
        SetSubItem(st->marketList, row, 4, p.hasStars ? std::to_wstring(p.stars) : L"");
        row++;
    }
    // Only report "no matches" when the market actually loaded; a load
    // failure leaves the error message from kPmMarketDone in the status bar.
    if (row == 0 && st->marketLoaded) SetStatus(st, st->s.emptyMarket);
}

// ---- state refresh ----

void LoadLocal(DialogState* st) {
    st->installed = InstalledPackages();
    st->enabled = EnabledBundles();
    st->tree = DependencyTree();
}

void UpdateButtons(DialogState* st) {
    bool enableOps = !st->busy;
    EnableWindow(GetDlgItem(st->hDlg, kIdcBtnEnable), enableOps && st->currentTab == 0);
    EnableWindow(GetDlgItem(st->hDlg, kIdcBtnDisable), enableOps && st->currentTab <= 1);
    EnableWindow(GetDlgItem(st->hDlg, kIdcBtnUninstall), enableOps && st->currentTab == 0);
    EnableWindow(GetDlgItem(st->hDlg, kIdcBtnInstall), enableOps && st->currentTab == 2);
    EnableWindow(GetDlgItem(st->hDlg, kIdcBtnOpen), enableOps && st->currentTab == 2);
    EnableWindow(GetDlgItem(st->hDlg, kIdcBtnRefresh), !st->busy);
    EnableWindow(GetDlgItem(st->hDlg, kIdcBtnLocalFile), !st->busy);
    EnableWindow(GetDlgItem(st->hDlg, kIdcBtnLocalDir), !st->busy);
    EnableWindow(GetDlgItem(st->hDlg, kIdcBtnRestart), TRUE);
}

// ---- selection helpers ----

PluginNode* SelectedInstalledNode(DialogState* st) {
    HTREEITEM h = reinterpret_cast<HTREEITEM>(
        SendMessageW(st->installedTree, TVM_GETNEXTITEM, TVGN_CARET, 0));
    if (!h) return nullptr;
    TVITEMW item{};
    item.hItem = h;
    item.mask = TVIF_PARAM;
    if (!SendMessageW(st->installedTree, TVM_GETITEMW, 0, reinterpret_cast<LPARAM>(&item))) {
        return nullptr;
    }
    return reinterpret_cast<PluginNode*>(item.lParam);
}

int SelectedMarketIndex(DialogState* st) {
    int sel = static_cast<int>(
        SendMessageW(st->marketList, LVM_GETNEXTITEM, static_cast<WPARAM>(-1), LVNI_SELECTED));
    if (sel < 0) return -1;
    LVITEMW it{};
    it.mask = LVIF_PARAM;
    it.iItem = sel;
    if (!SendMessageW(st->marketList, LVM_GETITEMW, 0, reinterpret_cast<LPARAM>(&it))) return -1;
    return static_cast<int>(it.lParam);
}

int SelectedEnabledIndex(DialogState* st) {
    return static_cast<int>(
        SendMessageW(st->enabledList, LVM_GETNEXTITEM, static_cast<WPARAM>(-1), LVNI_SELECTED));
}

void StartPluginCmd(DialogState* st, std::vector<std::wstring> args,
                    const std::wstring& busyText) {
    if (st->busy) return;
    st->busy = true;
    SetStatus(st, busyText);
    UpdateButtons(st);
    auto* ctx = new PluginCmdCtx{st->hDlg, std::move(args)};
    HANDLE h = CreateThread(nullptr, 0, PluginCmdThread, ctx, 0, nullptr);
    if (h) CloseHandle(h);
}

void RefreshMarket(DialogState* st) {
    if (st->busy) return;
    st->busy = true;
    SetStatus(st, st->s.loading);
    UpdateButtons(st);
    auto* ctx = new MarketCtx{st->hDlg, MainWindow::Instance().IsChinese()};
    HANDLE h = CreateThread(nullptr, 0, MarketLoadThread, ctx, 0, nullptr);
    if (h) CloseHandle(h);
}

// ---- actions ----

void ToggleSelectedEnabled(DialogState* st, bool enable) {
    auto* node = SelectedInstalledNode(st);
    if (!node) {
        SetStatus(st, st->s.noSelection);
        return;
    }
    std::wstring err;
    if (!SetEnabled(node->name, enable, err)) {
        SetStatus(st, node->name + L": " + err);
        return;
    }
    LoadLocal(st);
    FillInstalledTree(st);
    if (st->currentTab == 1) FillEnabledList(st);
    SetStatus(st, node->name + L" — " + (enable ? st->s.enabled : st->s.disabled) +
                      L" · " + st->s.restartHint);
}

void UninstallSelected(DialogState* st) {
    auto* node = SelectedInstalledNode(st);
    if (!node) {
        SetStatus(st, st->s.noSelection);
        return;
    }
    if (node->builtin) {
        SetStatus(st, st->s.cannotUninstallBuiltin);
        return;
    }
    if (!PnpmAvailable()) {
        SetStatus(st, st->s.pnpmMissing);
        return;
    }
    StartPluginCmd(st, {L"remove", node->name}, st->s.installing + L" " + node->name + L"…");
}

void DisableSelectedEnabled(DialogState* st) {
    int idx = SelectedEnabledIndex(st);
    if (idx < 0 || idx >= static_cast<int>(st->enabled.size())) {
        SetStatus(st, st->s.noSelection);
        return;
    }
    std::wstring err;
    if (!SetEnabled(st->enabled[idx], false, err)) {
        SetStatus(st, st->s.enabled[idx] + L": " + err);
        return;
    }
    LoadLocal(st);
    FillEnabledList(st);
    FillInstalledTree(st);
    SetStatus(st, st->s.enabled[idx] + L" — " + st->s.disabled + L" · " + st->s.restartHint);
}

void InstallMarketSelected(DialogState* st) {
    int idx = SelectedMarketIndex(st);
    if (idx < 0 || idx >= static_cast<int>(st->market.size())) {
        SetStatus(st, st->s.noSelection);
        return;
    }
    auto& p = st->market[idx];
    if (p.installSpec.empty()) {
        SetStatus(st, st->s.notInstallable);
        return;
    }
    if (!PnpmAvailable()) {
        SetStatus(st, st->s.pnpmMissing);
        return;
    }
    StartPluginCmd(st, {L"add", p.installSpec}, st->s.installing + L" " + p.installSpec + L"…");
}

void OpenMarketSelected(DialogState* st) {
    int idx = SelectedMarketIndex(st);
    if (idx < 0 || idx >= static_cast<int>(st->market.size())) {
        SetStatus(st, st->s.noSelection);
        return;
    }
    auto& p = st->market[idx];
    if (p.url.empty()) return;
    ShellExecuteW(nullptr, L"open", p.url.c_str(), nullptr, nullptr, SW_SHOWNORMAL);
}

void PickLocalInstall(DialogState* st, bool folder) {
    using Microsoft::WRL::ComPtr;
    ComPtr<IFileOpenDialog> dlg;
    if (FAILED(CoCreateInstance(CLSID_FileOpenDialog, nullptr, CLSCTX_INPROC_SERVER,
                                IID_PPV_ARGS(&dlg)))) {
        return;
    }
    DWORD opts = 0;
    dlg->GetOptions(&opts);
    if (folder) {
        dlg->SetOptions(opts | FOS_PICKFOLDERS | FOS_FORCEFILESYSTEM);
        dlg->SetTitle(st->s.selectDir.c_str());
    } else {
        dlg->SetOptions(opts | FOS_FORCEFILESYSTEM);
        COMDLG_FILTERSPEC filter = {st->s.tgzFilterName.c_str(), L"*.tgz;*.tar;*.gz"};
        dlg->SetFileTypes(1, &filter);
        dlg->SetTitle(st->s.selectFile.c_str());
    }
    if (FAILED(dlg->Show(st->hDlg))) return;
    ComPtr<IShellItem> item;
    if (FAILED(dlg->GetResult(&item))) return;
    wchar_t* raw = nullptr;
    if (FAILED(item->GetDisplayName(SIGDN_FILESYSPATH, &raw))) return;
    std::wstring path = raw;
    CoTaskMemFree(raw);

    if (folder) {
        if (GetFileAttributesW(JoinPath(path, L"package.json").c_str()) == INVALID_FILE_ATTRIBUTES) {
            SetStatus(st, st->s.badDir);
            return;
        }
    } else {
        if (!EndsWithIgnoreCase(path, L".tgz") && !EndsWithIgnoreCase(path, L".tar") &&
            !EndsWithIgnoreCase(path, L".gz")) {
            SetStatus(st, st->s.badFile);
            return;
        }
    }
    if (!PnpmAvailable()) {
        SetStatus(st, st->s.pnpmMissing);
        return;
    }
    StartPluginCmd(st, {L"add", path}, st->s.installing + L" " + path + L"…");
}

void SwitchTab(DialogState* st) {
    int sel = static_cast<int>(SendMessageW(st->tab, TCM_GETCURSEL, 0, 0));
    st->currentTab = sel;
    ShowWindow(st->installedTree, sel == 0 ? SW_SHOW : SW_HIDE);
    ShowWindow(st->enabledList, sel == 1 ? SW_SHOW : SW_HIDE);
    ShowWindow(st->marketList, sel == 2 ? SW_SHOW : SW_HIDE);
    ShowWindow(st->search, sel == 2 ? SW_SHOW : SW_HIDE);
    if (sel == 0) {
        FillInstalledTree(st);
    } else if (sel == 1) {
        FillEnabledList(st);
    } else {
        if (!st->marketLoaded && !st->busy) RefreshMarket(st);
        else if (st->marketLoaded) FillMarketList(st);
    }
    UpdateButtons(st);
}

// ---- dialog proc ----

INT_PTR CALLBACK PluginsDlgProc(HWND hDlg, UINT msg, WPARAM wParam, LPARAM lParam) {
    auto* st = reinterpret_cast<DialogState*>(GetWindowLongPtrW(hDlg, DWLP_USER));

    switch (msg) {
        case WM_INITDIALOG: {
            auto* zh = reinterpret_cast<bool*>(lParam);
            auto* state = new DialogState();
            state->s = Str(*zh);
            state->hDlg = hDlg;
            SetWindowLongPtrW(hDlg, DWLP_USER, reinterpret_cast<LONG_PTR>(state));
            st = state;

            RECT rc{};
            GetClientRect(hDlg, &rc);
            int W = rc.right;
            int H = rc.bottom;
            int margin = 10;
            int tabH = 24;
            int searchW = 170;
            int listTop = margin + tabH + 8;
            int statusH = 18;
            int btnH = 26;
            int listH = H - listTop - statusH - btnH * 2 - 30;

            state->tab = MakeCtrl(hDlg, L"SysTabControl32", kIdcTab, L"",
                                  WS_TABSTOP, margin, margin, W - margin * 2 - searchW - 8, tabH);
            state->search = MakeCtrl(hDlg, L"Edit", kIdcSearch, L"",
                                     WS_TABSTOP | ES_LEFT | WS_BORDER,
                                     W - margin - searchW, margin, searchW, tabH);
            state->installedTree = MakeCtrl(hDlg, L"SysTreeView32", kIdcInstalledTree, L"",
                                            WS_TABSTOP | TVS_HASBUTTONS | TVS_HASLINES |
                                                TVS_LINESATROOT | TVS_SHOWSELALWAYS,
                                            margin, listTop, W - margin * 2, listH);
            state->enabledList = MakeCtrl(hDlg, L"SysListView32", kIdcEnabledList, L"",
                                          WS_TABSTOP | LVS_REPORT | LVS_SINGLESEL | LVS_SHOWSELALWAYS,
                                          margin, listTop, W - margin * 2, listH);
            state->marketList = MakeCtrl(hDlg, L"SysListView32", kIdcMarketList, L"",
                                         WS_TABSTOP | LVS_REPORT | LVS_SINGLESEL | LVS_SHOWSELALWAYS,
                                         margin, listTop, W - margin * 2, listH);
            state->status = MakeCtrl(hDlg, L"Static", kIdcStatus, L"",
                                     SS_LEFT | SS_ENDELLIPSIS,
                                     margin, listTop + listH + 4, W - margin * 2, statusH);

            const wchar_t* row1Labels[] = {state->s.localFile.c_str(), state->s.localDir.c_str(),
                                           state->s.install.c_str(), state->s.uninstall.c_str(),
                                           state->s.enable.c_str(), state->s.disable.c_str(),
                                           state->s.open.c_str(), state->s.refresh.c_str()};
            const int row1Ids[] = {kIdcBtnLocalFile, kIdcBtnLocalDir, kIdcBtnInstall,
                                   kIdcBtnUninstall, kIdcBtnEnable, kIdcBtnDisable,
                                   kIdcBtnOpen, kIdcBtnRefresh};
            int btnW = 66;
            int gap = 6;
            int row1Count = static_cast<int>(sizeof(row1Ids) / sizeof(row1Ids[0]));
            int row1W = row1Count * btnW + (row1Count - 1) * gap;
            int x1 = W - margin - row1W;
            int y1 = listTop + listH + statusH + 8;
            for (int i = 0; i < row1Count; i++) {
                HWND b = MakeCtrl(hDlg, L"Button", row1Ids[i], row1Labels[i],
                                  WS_TABSTOP | BS_PUSHBUTTON,
                                  x1 + i * (btnW + gap), y1, btnW, btnH);
                ApplyFont(b, hDlg);
            }
            HWND restart = MakeCtrl(hDlg, L"Button", kIdcBtnRestart, state->s.restartNow.c_str(),
                                    WS_TABSTOP | BS_PUSHBUTTON,
                                    W - margin - btnW - gap - 66, y1 + btnH + 6, 66, btnH);
            ApplyFont(restart, hDlg);
            HWND closeBtn = MakeCtrl(hDlg, L"Button", IDCANCEL, state->s.close.c_str(),
                                     WS_TABSTOP | BS_PUSHBUTTON,
                                     W - margin - btnW, y1 + btnH + 6, btnW, btnH);
            ApplyFont(closeBtn, hDlg);

            ApplyFont(state->tab, hDlg);
            ApplyFont(state->search, hDlg);
            ApplyFont(state->installedTree, hDlg);
            ApplyFont(state->enabledList, hDlg);
            ApplyFont(state->marketList, hDlg);
            ApplyFont(state->status, hDlg);

            TCITEMW ti{};
            ti.mask = TCIF_TEXT;
            ti.pszText = const_cast<wchar_t*>(state->s.tabInstalled.c_str());
            SendMessageW(state->tab, TCM_INSERTITEMW, 0, reinterpret_cast<LPARAM>(&ti));
            ti.pszText = const_cast<wchar_t*>(state->s.tabEnabled.c_str());
            SendMessageW(state->tab, TCM_INSERTITEMW, 1, reinterpret_cast<LPARAM>(&ti));
            ti.pszText = const_cast<wchar_t*>(state->s.tabMarket.c_str());
            SendMessageW(state->tab, TCM_INSERTITEMW, 2, reinterpret_cast<LPARAM>(&ti));
            SendMessageW(state->tab, TCM_SETCURSEL, 0, 0);

            LoadLocal(state);
            ShowWindow(state->enabledList, SW_HIDE);
            ShowWindow(state->marketList, SW_HIDE);
            ShowWindow(state->search, SW_HIDE);
            FillInstalledTree(state);
            UpdateButtons(state);
            RefreshMarket(state);
            return TRUE;
        }

        case WM_NOTIFY: {
            auto* nm = reinterpret_cast<NMHDR*>(lParam);
            if (!st) return FALSE;
            if (nm->idFrom == kIdcTab && nm->code == TCN_SELCHANGE) {
                SwitchTab(st);
                return TRUE;
            }
            break;
        }

        case WM_COMMAND: {
            if (!st) return FALSE;
            switch (LOWORD(wParam)) {
                case kIdcSearch:
                    if (HIWORD(wParam) == EN_CHANGE) {
                        wchar_t buf[256] = {};
                        GetWindowTextW(st->search, buf, 256);
                        st->searchText = buf;
                        if (st->currentTab == 2 && st->marketLoaded) FillMarketList(st);
                    }
                    return TRUE;
                case kIdcBtnInstall: InstallMarketSelected(st); return TRUE;
                case kIdcBtnUninstall: UninstallSelected(st); return TRUE;
                case kIdcBtnEnable: ToggleSelectedEnabled(st, true); return TRUE;
                case kIdcBtnDisable:
                    if (st->currentTab == 1) DisableSelectedEnabled(st);
                    else ToggleSelectedEnabled(st, false);
                    return TRUE;
                case kIdcBtnOpen: OpenMarketSelected(st); return TRUE;
                case kIdcBtnRefresh:
                    LoadLocal(st);
                    FillInstalledTree(st);
                    FillEnabledList(st);
                    RefreshMarket(st);
                    return TRUE;
                case kIdcBtnLocalFile: PickLocalInstall(st, false); return TRUE;
                case kIdcBtnLocalDir: PickLocalInstall(st, true); return TRUE;
                case kIdcBtnRestart:
                    MainWindow::Instance().RestartServer();
                    return TRUE;
                case IDCANCEL:
                    EndDialog(hDlg, IDCANCEL);
                    return TRUE;
            }
            return TRUE;
        }

        case kPmMarketDone: {
            auto* res = reinterpret_cast<MarketResult*>(lParam);
            if (st) {
                st->busy = false;
                st->marketLoaded = true;
                st->market = std::move(res->plugins);
                SetStatus(st, res->error.empty() ? L"" : st->s.marketFailed + L": " + res->error);
                if (st->currentTab == 2) FillMarketList(st);
                UpdateButtons(st);
            }
            delete res;
            return TRUE;
        }

        case kPmPluginDone: {
            bool ok = wParam != 0;
            auto* out = reinterpret_cast<std::wstring*>(lParam);
            if (st) {
                st->busy = false;
                LoadLocal(st);
                FillInstalledTree(st);
                FillEnabledList(st);
                if (st->currentTab == 2 && st->marketLoaded) FillMarketList(st);
                std::wstring msg = ok ? st->s.doneInstall : st->s.opFailed;
                if (out && !out->empty()) msg += L": " + *out;
                SetStatus(st, msg);
                UpdateButtons(st);
            }
            delete out;
            return TRUE;
        }

        case WM_DESTROY:
            delete st;
            SetWindowLongPtrW(hDlg, DWLP_USER, 0);
            return TRUE;
    }
    return FALSE;
}

} // namespace

// ---- public entry ----

void Show(HWND owner) {
    static bool commonControlsDone = [] {
        INITCOMMONCONTROLSEX icc{};
        icc.dwSize = sizeof(icc);
        icc.dwICC = ICC_TAB_CLASSES | ICC_LISTVIEW_CLASSES | ICC_TREEVIEW_CLASSES;
        return InitCommonControlsEx(&icc) != FALSE;
    }();
    (void)commonControlsDone;

    bool zh = MainWindow::Instance().IsChinese();
    std::wstring title = zh ? L"插件管理" : L"Plugins";
    std::vector<TemplateItem> items; // all controls are created in WM_INITDIALOG
    HGLOBAL tmpl = BuildDialogTemplate(title.c_str(), 400, 300, items);
    if (!tmpl) return;
    DialogBoxIndirectParamW(GetModuleHandleW(nullptr),
                            reinterpret_cast<LPCDLGTEMPLATEW>(tmpl),
                            owner, PluginsDlgProc, reinterpret_cast<LPARAM>(&zh));
    GlobalFree(tmpl);
}

} // namespace PluginsManager
} // namespace dsh
