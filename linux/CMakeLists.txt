cmake_minimum_required(VERSION 3.16)
project(dshwebview LANGUAGES CXX C)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# App version shown in the About dialog (override at release time, e.g.
# -DAPP_VERSION=1.1.1).
set(APP_VERSION "1.1.9" CACHE STRING "App version shown in About")

# ---- Dependencies (system WebKitGTK = the Linux webview, like WKWebView /
# WebView2 on the other platforms) ----
find_package(PkgConfig REQUIRED)
pkg_check_modules(WEBKIT REQUIRED IMPORTED_TARGET webkit2gtk-4.1)
pkg_check_modules(GTK3 REQUIRED IMPORTED_TARGET gtk+-3.0)
pkg_check_modules(SOUP3 REQUIRED IMPORTED_TARGET libsoup-3.0)

add_executable(dshwebview
    src/main.cpp
    src/settings.cpp
    src/util.cpp
    src/server_manager.cpp
    src/update_manager.cpp
    src/node_runtime_manager.cpp
    src/json.cpp
    src/plugins_manager.cpp
    src/main_window.cpp
    ../third_party/qrcodegen/qrcodegen.c
)

target_include_directories(dshwebview PRIVATE src ../third_party/qrcodegen)

target_compile_definitions(dshwebview PRIVATE APP_VERSION="${APP_VERSION}")

target_link_libraries(dshwebview PRIVATE
    PkgConfig::WEBKIT
    PkgConfig::GTK3
    PkgConfig::SOUP3
)

target_compile_options(dshwebview PRIVATE -Wall -Wextra)
