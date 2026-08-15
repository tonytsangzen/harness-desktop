#!/usr/bin/env bash
# Build the Windows native C++/WebView2 shell. Intended to run on a Windows
# machine or the `windows-latest` GitHub runner, where Visual Studio 2022
# (MSVC, CMake, Ninja) is available.
set -euo pipefail
cd "$(dirname "$0")"

# Locate the CMake/Ninja that ships with Visual Studio.
VSWHERE="${PROGRAMFILES(x86)}/Microsoft Visual Studio/Installer/vswhere.exe"
if [[ -f "${VSWHERE}" ]]; then
  VSROOT="$("${VSWHERE}" -latest -property installationPath 2>/dev/null | tr -d '\r')"
else
  VSROOT="${ProgramFiles}/Microsoft Visual Studio/2022/Community"
fi
CMK="${VSROOT}/Common7/IDE/CommonExtensions/Microsoft/CMake/CMake/bin/cmake.exe"
NINJA="${VSROOT}/Common7/IDE/CommonExtensions/Microsoft/CMake/Ninja/ninja.exe"
VCVARS="${VSROOT}/VC/Auxiliary/Build/vcvars64.bat"

if [[ ! -f "${CMK}" || ! -f "${VCVARS}" ]]; then
  echo "error: Visual Studio 2022 with the C++ workload is required." >&2
  exit 1
fi

# Build into windows/build.
cmd //c "call \"${VCVARS}\" >nul && \"${CMK}\" -S windows -B windows/build -G Ninja \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_MAKE_PROGRAM=\"${NINJA}\" && \"${CMK}\" --build windows/build"

# Publish the single exe into dist/windows.
DIST="dist/windows"
rm -rf "${DIST}"
mkdir -p "${DIST}"
cp windows/build/DSHWebView.exe "${DIST}/DSHWebView.exe"

echo "Built: ${DIST}/DSHWebView.exe ($(du -h "${DIST}/DSHWebView.exe" | cut -f1))"
echo "Run:   ${DIST}/DSHWebView.exe"
echo "Requires on target: Microsoft Edge WebView2 Evergreen Runtime (preinstalled on Win11 / shipped with Edge)."
