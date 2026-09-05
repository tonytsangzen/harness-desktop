cmake_minimum_required(VERSION 3.18)
project(DSHWebView LANGUAGES CXX C)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# App version shown in the About dialog (override at release time, e.g.
# -DAPP_VERSION=1.1.1).
set(APP_VERSION "1.2.1" CACHE STRING "App version shown in About")

if(NOT MSVC)
    message(FATAL_ERROR "DSHWebView requires MSVC (Visual Studio 2022).")
endif()

# ---- WebView2 SDK (Microsoft.Web.WebView2 NuGet) ----
set(WEBVIEW2_VERSION "1.0.4129.50")
set(WEBVIEW2_URL "https://api.nuget.org/v3-flatcontainer/microsoft.web.webview2/${WEBVIEW2_VERSION}/microsoft.web.webview2.${WEBVIEW2_VERSION}.nupkg")
set(WEBVIEW2_ROOT "${CMAKE_BINARY_DIR}/_deps/webview2-sdk")
set(WEBVIEW2_INCLUDE "${WEBVIEW2_ROOT}/build/native/include")

# Pick the static loader for the target architecture (x64 or arm64).
# Note: with the Visual Studio generator, CMAKE_SYSTEM_PROCESSOR always reports
# the host architecture, so the platform name is the reliable signal.
if(CMAKE_SYSTEM_PROCESSOR MATCHES "ARM64|aarch64" OR
   CMAKE_GENERATOR_PLATFORM MATCHES "ARM64|arm64" OR
   CMAKE_VS_PLATFORM_NAME MATCHES "ARM64|arm64")
    set(WEBVIEW2_LIB "${WEBVIEW2_ROOT}/build/native/arm64/WebView2LoaderStatic.lib")
else()
    set(WEBVIEW2_LIB "${WEBVIEW2_ROOT}/build/native/x64/WebView2LoaderStatic.lib")
endif()

if(NOT EXISTS "${WEBVIEW2_LIB}")
    message(STATUS "Downloading Microsoft.Web.WebView2 ${WEBVIEW2_VERSION} ...")
    file(DOWNLOAD "${WEBVIEW2_URL}" "${WEBVIEW2_ROOT}/webview2.nupkg" STATUS dl_status)
    list(GET dl_status 0 dl_code)
    if(NOT dl_code EQUAL 0)
        message(FATAL_ERROR "Failed to download WebView2 SDK: ${dl_status}")
    endif()
    file(ARCHIVE_EXTRACT INPUT "${WEBVIEW2_ROOT}/webview2.nupkg" DESTINATION "${WEBVIEW2_ROOT}")
endif()

if(NOT EXISTS "${WEBVIEW2_LIB}")
    message(FATAL_ERROR "WebView2 loader for this architecture not found: ${WEBVIEW2_LIB}")
endif()

# Static CRT so the exe has no vcruntime dependency (single portable binary).
set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")

add_executable(DSHWebView WIN32
    src/main.cpp
    src/settings.cpp
    src/node_runtime_manager.cpp
    src/server_manager.cpp
    src/dsh_update_manager.cpp
    src/http.cpp
    src/json.cpp
    src/util.cpp
    src/plugins_manager.cpp
    src/main_window.cpp
    ../third_party/qrcodegen/qrcodegen.c
    resources.rc
)

target_include_directories(DSHWebView PRIVATE src ../third_party/qrcodegen "${WEBVIEW2_INCLUDE}")

target_compile_definitions(DSHWebView PRIVATE APP_VERSION="${APP_VERSION}")

target_link_libraries(DSHWebView PRIVATE
    "${WEBVIEW2_LIB}"
    winhttp ws2_32 shell32 shlwapi ole32 oleaut32 comctl32 advapi32 version user32 gdi32 uuid crypt32 dwmapi gdiplus iphlpapi
)

target_compile_options(DSHWebView PRIVATE /W3 /wd4996 /utf-8)

# Disable the linker's auto-generated manifest; resources.rc embeds app.manifest.
target_link_options(DSHWebView PRIVATE "/MANIFEST:NO" "/ENTRY:wWinMainCRTStartup")

set_target_properties(DSHWebView PROPERTIES OUTPUT_NAME "DSHWebView")
