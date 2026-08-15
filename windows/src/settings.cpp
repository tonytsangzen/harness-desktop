#include "settings.h"

#include "util.h"

#include <cstdio>
#include <stdexcept>

namespace dsh {

const wchar_t* kUsageText = L"Usage: DSHWebView [--host <host>] [--port <port>] [--command \"<cmd>\"] [--help]\n"
    L"\n"
    L"Wraps the DeepSeek Harness web UI (`npx @deepseek-ai/dsh web`) in a native\n"
    L"Windows WebView2 window.\n"
    L"\n"
    L"  --host <host>      Host for the dsh web server (default: 127.0.0.1)\n"
    L"  --port <port>      Port for the dsh web server (default: 3080)\n"
    L"  --command \"<cmd>\"  Full command to launch dsh web (space-separated)\n"
    L"  --help             Show this help\n"
    L"\n"
    L"Environment:\n"
    L"  DSH_WEBVIEW_HOST      overrides the default host\n"
    L"  DSH_WEBVIEW_PORT      overrides the default port\n"
    L"  DSH_WEBVIEW_COMMAND   overrides the launch command\n";

Settings Settings::Parse(const std::vector<std::wstring>& args) {
    Settings s;

    auto envHost = GetEnv(L"DSH_WEBVIEW_HOST");
    if (!envHost.empty()) s.host = envHost;

    auto envPort = GetEnv(L"DSH_WEBVIEW_PORT");
    if (!envPort.empty()) {
        try {
            unsigned long v = std::stoul(envPort);
            if (v <= 65535) s.port = static_cast<unsigned short>(v);
        } catch (...) {}
    }

    auto envCmd = GetEnv(L"DSH_WEBVIEW_COMMAND");
    if (!envCmd.empty()) {
        s.command = SplitWhitespace(envCmd);
        s.customCommand = true;
    }

    for (size_t i = 0; i < args.size(); i++) {
        const auto& arg = args[i];
        if (arg == L"--host" && i + 1 < args.size()) {
            s.host = args[++i];
        } else if (arg == L"--port" && i + 1 < args.size()) {
            try {
                unsigned long v = std::stoul(args[i + 1]);
                if (v <= 65535) s.port = static_cast<unsigned short>(v);
                i++;
            } catch (...) {
                throw std::runtime_error("invalid --port value");
            }
        } else if (arg == L"--command" && i + 1 < args.size()) {
            s.command = SplitWhitespace(args[++i]);
            s.customCommand = true;
        } else if (arg == L"--help" || arg == L"-h") {
            fputws(kUsageText, stderr);
            exit(0);
        } else {
            throw std::runtime_error("unknown argument");
        }
    }

    // Keep the webview and the server in agreement for the default command.
    bool isDefaultNpx = s.command.size() == 3 && s.command[0] == L"npx" &&
                        s.command[1] == L"@deepseek-ai/dsh" && s.command[2] == L"web";
    if (!s.customCommand && isDefaultNpx) {
        s.command.push_back(L"--host");
        s.command.push_back(s.host);
        s.command.push_back(L"--port");
        s.command.push_back(std::to_wstring(s.port));
    }

    return s;
}

} // namespace dsh
