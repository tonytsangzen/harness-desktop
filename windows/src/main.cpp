#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include <combaseapi.h>
#include <shellapi.h>

#include <cstring>
#include <string>
#include <vector>

#include "main_window.h"
#include "server_manager.h"
#include "settings.h"
#include "util.h"

int APIENTRY wWinMain(HINSTANCE instance, HINSTANCE /*prevInstance*/, PWSTR /*cmdLine*/, int /*cmdShow*/) {
    HRESULT hr = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    if (FAILED(hr)) return 1;

    // Parse the command line (excluding argv[0]).
    std::vector<std::wstring> args;
    {
        int argc = 0;
        LPWSTR* argv = CommandLineToArgvW(GetCommandLineW(), &argc);
        if (argv) {
            for (int i = 1; i < argc; i++) args.push_back(argv[i]);
            LocalFree(argv);
        }
    }

    try {
        auto settings = dsh::Settings::Parse(args);
        dsh::ServerManager::Initialize(settings);

        auto& win = dsh::MainWindow::Instance();
        if (!win.Create(instance, L"DeepSeek Harness")) return 1;
        win.Show();
        win.Run();
    } catch (const std::exception& e) {
        std::wstring msg = std::wstring(L"DSH WebView: ") +
                           std::wstring(e.what(), e.what() + strlen(e.what()));
        MessageBoxW(nullptr, msg.c_str(), L"DSH WebView", MB_ICONERROR | MB_OK);
    }

    CoUninitialize();
    return 0;
}
