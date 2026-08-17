#pragma once

#include <functional>
#include <string>

namespace dsh {

struct Settings;

// Launches and supervises the dsh web server process (`npx @deepseek-ai/dsh
// web ...`). WaitUntilReady() polls the HTTP port until the server accepts
// connections, with a generous timeout for first start.
namespace ServerManager {

void Initialize(const Settings& settings);

// Returns a quoted, shell-ready command line, e.g.
//   "C:\path\node.exe" "C:\path\node_modules\npm\bin\npx-cli.js" @deepseek-ai/dsh web --host ...
// Throws std::runtime_error on failure.
std::wstring PrepareCommandLine();

// Resolves `npx` to its full path (node.exe + npx-cli.js when possible).
std::wstring ResolveNpx(const std::wstring& requested);

// Spawns the server process. Returns true on success.
bool Start();

// True while the server process is still alive.
bool IsRunning();

// Stops the server and kills the whole process tree (via job object).
void Stop();

// Polls the port until the server responds or the timeout elapses.
// Returns true when ready. `onWaiting` is invoked periodically while waiting.
// The countdown is reset whenever the child writes new log output, so a
// slow-but-progressing startup (e.g. npx installing the dsh package) isn't
// killed by the timeout. Each complete log line is forwarded to the handler
// set with SetLogHandler (called on the calling thread).
bool WaitUntilReady(int timeoutMs, const std::function<void()>& onWaiting = {});

// Sets the handler invoked (on the WaitUntilReady caller's thread) with each
// complete line of the server's stdout/stderr. The UI uses it to show the
// last line on the loading screen.
void SetLogHandler(const std::function<void(const std::wstring&)>& handler);

unsigned short Port();
std::wstring Host();
std::wstring Url();

// True when host:port already serves a web page (an existing dsh instance
// worth reusing instead of spawning a second, empty one).
bool LooksLikeDshWeb(const std::wstring& host, unsigned short port);

} // namespace ServerManager
} // namespace dsh
