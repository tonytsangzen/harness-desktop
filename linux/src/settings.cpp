#include "settings.h"

#include <cstdlib>

namespace dsh {

const char* kUsageText =
    "Usage: dshwebview [--host <host>] [--port <port>] [--command \"<cmd>\"] [--help]\n"
    "\n"
    "Wraps the DeepSeek Harness web UI (`npx @deepseek-ai/dsh web`) in a native\n"
    "WebKitGTK window.\n"
    "\n"
    "  --host <host>      Host for the dsh web server (default: 127.0.0.1)\n"
    "  --port <port>      Port for the dsh web server (default: 3080)\n"
    "  --command \"<cmd>\"  Full command to launch dsh web (space-separated)\n"
    "  --help             Show this help\n"
    "\n"
    "Environment:\n"
    "  DSH_WEBVIEW_HOST      overrides the default host\n"
    "  DSH_WEBVIEW_PORT      overrides the default port\n"
    "  DSH_WEBVIEW_COMMAND   overrides the launch command\n";

static std::vector<std::string> SplitWhitespace(const std::string& s) {
    std::vector<std::string> out;
    std::string cur;
    for (char c : s) {
        if (c == ' ' || c == '\t' || c == '\n') {
            if (!cur.empty()) { out.push_back(cur); cur.clear(); }
        } else {
            cur.push_back(c);
        }
    }
    if (!cur.empty()) out.push_back(cur);
    return out;
}

static std::string GetEnv(const char* name) {
    const char* v = std::getenv(name);
    return v ? std::string(v) : std::string();
}

Settings Settings::Parse(const std::vector<std::string>& args) {
    Settings s;
    if (auto v = GetEnv("DSH_WEBVIEW_HOST"); !v.empty()) s.host = v;
    if (auto v = GetEnv("DSH_WEBVIEW_PORT"); !v.empty()) s.port = static_cast<unsigned short>(std::atoi(v.c_str()));
    if (auto v = GetEnv("DSH_WEBVIEW_COMMAND"); !v.empty()) s.command = SplitWhitespace(v);

    for (size_t i = 0; i < args.size(); ++i) {
        const std::string& arg = args[i];
        if (arg == "--host") {
            if (i + 1 < args.size()) s.host = args[++i];
        } else if (arg == "--port") {
            if (i + 1 < args.size()) s.port = static_cast<unsigned short>(std::atoi(args[++i].c_str()));
        } else if (arg == "--command") {
            if (i + 1 < args.size()) {
                s.command = SplitWhitespace(args[++i]);
                s.customCommand = true;
            }
        } else if (arg == "--help" || arg == "-h") {
            fputs(kUsageText, stderr);
            std::exit(0);
        }
    }
    return s;
}

} // namespace dsh
