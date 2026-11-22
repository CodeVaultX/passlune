#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <algorithm>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
#ifdef NDEBUG
  // One Passlune at a time (it may be sitting in the notification area):
  // a second start brings the running one forward and exits. Debug builds
  // skip this so tests can run next to an installed copy.
  HANDLE single = CreateMutexW(nullptr, TRUE, L"Local\\Passlune.SingleInstance");
  if (single && GetLastError() == ERROR_ALREADY_EXISTS) {
    HWND other = FindWindowW(L"FLUTTER_RUNNER_WIN32_WINDOW", L"Passlune");
    if (other) {
      DWORD pid = 0;
      GetWindowThreadProcessId(other, &pid);
      AllowSetForegroundWindow(pid);
      PostMessageW(other, FlutterWindow::ShowMessage(), 0, 0);
    }
    return EXIT_SUCCESS;
  }
#endif

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();
  // Added to the startup entry when "start with Windows" is on.
  const bool in_tray =
      std::find(command_line_arguments.begin(), command_line_arguments.end(),
                "--tray") != command_line_arguments.end();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  window.SetStartInTray(in_tray);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"Passlune", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
