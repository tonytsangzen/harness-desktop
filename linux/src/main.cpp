#include "main_window.h"
#include "server_manager.h"
#include "settings.h"

#include <gtk/gtk.h>

#include <string>
#include <vector>

int main(int argc, char** argv) {
    // Parse arguments before touching GTK so --help works without a display.
    std::vector<std::string> args;
    for (int i = 1; i < argc; ++i) args.emplace_back(argv[i]);
    auto settings = dsh::Settings::Parse(args); // exits on --help

    if (!gtk_init_check(&argc, &argv)) {
        g_printerr("dshwebview: could not initialize GTK (no display available?)\n");
        return 1;
    }

    dsh::ServerManager::Initialize(settings);

    dsh::MainWindow window;
    if (!window.Init(settings)) return 1;
    window.Run();
    return 0;
}
