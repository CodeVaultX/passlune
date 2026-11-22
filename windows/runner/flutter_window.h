#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>

#include <shellapi.h>

#include <memory>
#include <string>

#include "win32_window.h"

// A window that hosts a Flutter view, and can live on in the notification
// area (system tray) when closed.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

  // Started by Windows at sign-in (--tray): stay in the notification area
  // instead of showing the window. Call before Create().
  void SetStartInTray(bool in_tray) { start_in_tray_ = in_tray; }

  // Message a second Passlune.exe posts to bring this window forward.
  static UINT ShowMessage();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // passlune/windows: copying and wiping secrets (lib/secure_clipboard.dart).
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;

  // Clipboard sequence number right after the last secret was copied, so a
  // wipe never empties something the user copied afterwards. 0: none.
  DWORD secret_clipboard_seq_ = 0;

  void ClearSecret();

  // Notification area. With |tray_enabled_| closing the window only hides it;
  // Quit in the icon's menu really exits.
  bool start_in_tray_ = false;
  bool tray_enabled_ = false;
  bool tray_added_ = false;
  bool quitting_ = false;
  bool hint_shown_ = false;
  // Menu texts, set from Dart in the app's language.
  std::wstring label_open_ = L"Open Passlune";
  std::wstring label_lock_ = L"Lock";
  std::wstring label_quit_ = L"Quit";
  std::wstring hint_title_ = L"Passlune is still running";
  std::wstring hint_text_ = L"Open it from this icon.";

  void AddTrayIcon();
  void RemoveTrayIcon();
  void ShowTrayHint();
  void ShowFromTray();
  void ShowTrayMenu();
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
