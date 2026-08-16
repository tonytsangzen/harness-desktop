# Cross-compilation toolchain for Linux arm64 (aarch64).
#
# Both Linux CI jobs run on ubuntu-22.04 (glibc 2.35) so the arm64 binary gets
# the same glibc baseline as x86_64 and runs on Ubuntu 22.04+ / Debian 12+ —
# not just on distros with the newest glibc. Requires, on the build host:
#   dpkg --add-architecture arm64 && apt-get update
#   apt-get install crossbuild-essential-arm64 \
#       libwebkit2gtk-4.1-dev:arm64 libgtk-3-dev:arm64 libsoup-3.0-dev:arm64
# plus PKG_CONFIG_LIBDIR=/usr/lib/aarch64-linux-gnu/pkgconfig and
# PKG_CONFIG_SYSROOT_DIR=/usr/aarch64-linux-gnu so pkg-config resolves the
# arm64 development packages (Ubuntu's /usr/aarch64-linux-gnu sysroot is a
# symlink to /usr, so prefixed paths resolve correctly).

set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR aarch64)

set(CMAKE_C_COMPILER aarch64-linux-gnu-gcc)
set(CMAKE_CXX_COMPILER aarch64-linux-gnu-g++)

set(CMAKE_FIND_ROOT_PATH /usr/aarch64-linux-gnu)
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)

# Let pkg_check_modules resolve the arm64 .pc files regardless of the caller's
# environment. PKG_CONFIG_LIBDIR must include /usr/share/pkgconfig too:
# arch-independent .pc files (e.g. xproto.pc from x11proto-core-dev) live
# there, and --exists walks the whole dependency tree — without them the
# lookup fails with "Package not found".
#
# Note: no PKG_CONFIG_SYSROOT_DIR here. The arm64 dev packages are native
# multiarch packages installed on the host (/usr/lib/aarch64-linux-gnu), and
# gcc's --sysroot does not redirect explicit -I/-L arguments, so pkg-config
# must emit the real host paths: headers come from the shared /usr/include
# tree, arch-specific bits (glibconfig.h) and libraries from
# /usr/lib/aarch64-linux-gnu.
set(ENV{PKG_CONFIG_LIBDIR} "/usr/lib/aarch64-linux-gnu/pkgconfig:/usr/share/pkgconfig")
