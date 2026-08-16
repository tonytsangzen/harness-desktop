#pragma once

#include <glib.h>

#include <functional>
#include <string>

namespace dsh {

struct Settings;

// Launches and supervises the dsh web server process (`npx @deepseek-ai/dsh
// web ...`). Mirrors the macOS/Windows ServerManager.
namespace ServerManager {

void Initialize(const Settings& settings);

// True when a usable node/npx is available on PATH.
bool NodeAvailable(std::string* missingTool);

// Spawns the server process. Returns true on success.
bool Start();

// Stops the server (kills the whole process group).
void Stop();

// True while the server process is still alive.
bool IsRunning();

// Probes whether something already listens on host:port.
bool TcpProbe(const std::string& host, unsigned short port, int timeoutMs);

// Resolves the port the server should bind: the configured port when free,
// otherwise the next free one (never kills an existing process).
unsigned short ResolvePort(const Settings& settings);

unsigned short ActivePort();

// Path of the server log file.
std::string LogPath();

} // namespace ServerManager
} // namespace dsh
