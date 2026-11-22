#include "flutter_window.h"

#include <flutter/standard_method_codec.h>

#include <optional>
#include <string>

#include "flutter/generated_plugin_registrant.h"
#include "resource.h"

#ifndef WDA_EXCLUDEFROMCAPTURE
#define WDA_EXCLUDEFROMCAPTURE 0x00000011
#endif

namespace {

// Notification-area icon: its callback message and menu commands.
constexpr UINT kTrayMessage = WM_APP + 1;
constexpr UINT kTrayId = 1;
constexpr UINT kCmdOpen = 1;
constexpr UINT kCmdLock = 2;
constexpr UINT kCmdQuit = 3;

// Start with Windows: a value under the user's Run key (no admin needed).
// Task Manager's Startup tab switches it off through StartupApproved.
constexpr wchar_t kRunKey[] = L"Software\\Microsoft\\Windows\\CurrentVersion\\Run";
constexpr wchar_t kApprovedKey[] =
    L"Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\StartupApproved\\Run";
constexpr wchar_t kRunValue[] = L"Passlune";

std::wstring Widen(const std::string& utf8) {
  int len = MultiByteToWideChar(CP_UTF8, 0, utf8.data(),
                                static_cast<int>(utf8.size()), nullptr, 0);
  std::wstring out(len, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, utf8.data(), static_cast<int>(utf8.size()),
                      out.data(), len);
  return out;
}

bool AutostartEnabled() {
  DWORD size = 0;
  if (RegGetValueW(HKEY_CURRENT_USER, kRunKey, kRunValue, RRF_RT_REG_SZ,
                   nullptr, nullptr, &size) != ERROR_SUCCESS) {
    return false;
  }
  // First byte odd (03, 07): switched off in Task Manager or Settings.
  BYTE approved[12];
  DWORD approved_size = sizeof(approved);
  if (RegGetValueW(HKEY_CURRENT_USER, kApprovedKey, kRunValue,
                   RRF_RT_REG_BINARY, nullptr, approved,
                   &approved_size) == ERROR_SUCCESS &&
      approved_size > 0 && (approved[0] & 1)) {
    return false;
  }
  return true;
}

bool SetAutostart(bool on, bool in_tray) {
  if (!on) {
    LSTATUS s = RegDeleteKeyValueW(HKEY_CURRENT_USER, kRunKey, kRunValue);
    return s == ERROR_SUCCESS || s == ERROR_FILE_NOT_FOUND;
  }
  wchar_t exe[MAX_PATH * 4];
  DWORD n = GetModuleFileNameW(nullptr, exe, ARRAYSIZE(exe));
  if (n == 0 || n >= ARRAYSIZE(exe)) {
    return false;
  }
  std::wstring cmd = L"\"" + std::wstring(exe, n) + L"\"";
  if (in_tray) {
    cmd += L" --tray";
  }
  if (RegSetKeyValueW(HKEY_CURRENT_USER, kRunKey, kRunValue, REG_SZ,
                      cmd.c_str(),
                      static_cast<DWORD>((cmd.size() + 1) * sizeof(wchar_t))) !=
      ERROR_SUCCESS) {
    return false;
  }
  // Turning it on here also undoes an earlier "Disable" in Task Manager.
  RegDeleteKeyValueW(HKEY_CURRENT_USER, kApprovedKey, kRunValue);
  return true;
}

// Hands |size| bytes of |data| to the open clipboard as |format|.
bool SetClipboardBytes(UINT format, const void* data, size_t size) {
  HGLOBAL mem = GlobalAlloc(GMEM_MOVEABLE, size);
  if (!mem) {
    return false;
  }
  void* p = GlobalLock(mem);
  memcpy(p, data, size);
  GlobalUnlock(mem);
  if (!SetClipboardData(format, mem)) {
    GlobalFree(mem);
    return false;
  }
  return true;  // the clipboard owns |mem| now
}

// Puts |utf8| on the clipboard marked as private: kept out of clipboard
// history (Win+V), cloud clipboard sync and clipboard monitors.
bool CopySecretText(HWND owner, const std::string& utf8) {
  int len = MultiByteToWideChar(CP_UTF8, 0, utf8.data(),
                                static_cast<int>(utf8.size()), nullptr, 0);
  std::wstring text(len, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, utf8.data(), static_cast<int>(utf8.size()),
                      text.data(), len);
  if (!OpenClipboard(owner)) {
    SecureZeroMemory(text.data(), text.size() * sizeof(wchar_t));
    return false;
  }
  EmptyClipboard();
  bool ok = SetClipboardBytes(CF_UNICODETEXT, text.c_str(),
                              (text.size() + 1) * sizeof(wchar_t));
  const DWORD no = 0;
  for (const wchar_t* name :
       {L"ExcludeClipboardContentFromMonitorProcessing",
        L"CanIncludeInClipboardHistory", L"CanUploadToCloudClipboard"}) {
    SetClipboardBytes(RegisterClipboardFormat(name), &no, sizeof(no));
  }
  CloseClipboard();
  SecureZeroMemory(text.data(), text.size() * sizeof(wchar_t));
  return ok;
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());

  // Keep the vault out of screenshots, recordings and screen sharing, like
  // FLAG_SECURE on Android. Windows 10 before 2004 shows it black instead.
  if (!SetWindowDisplayAffinity(GetHandle(), WDA_EXCLUDEFROMCAPTURE)) {
    SetWindowDisplayAffinity(GetHandle(), WDA_MONITOR);
  }

  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "passlune/windows",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    if (call.method_name() == "copySecret") {
      const auto* text = std::get_if<std::string>(call.arguments());
      if (!text) {
        result->Error("bad_args", "text expected");
      } else if (!CopySecretText(GetHandle(), *text)) {
        result->Error("clipboard", "Unable to open the clipboard");
      } else {
        secret_clipboard_seq_ = GetClipboardSequenceNumber();
        result->Success();
      }
    } else if (call.method_name() == "clearClipboard") {
      ClearSecret();
      result->Success();
    } else if (call.method_name() == "setTray") {
      // {enabled, open, lock, quit, hintTitle, hintText}
      const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
      if (!args) {
        result->Error("bad_args", "map expected");
        return;
      }
      auto text = [args](const char* key, std::wstring& out) {
        auto it = args->find(flutter::EncodableValue(key));
        if (it != args->end()) {
          if (const auto* s = std::get_if<std::string>(&it->second)) {
            out = Widen(*s);
          }
        }
      };
      text("open", label_open_);
      text("lock", label_lock_);
      text("quit", label_quit_);
      text("hintTitle", hint_title_);
      text("hintText", hint_text_);
      auto enabled = args->find(flutter::EncodableValue("enabled"));
      const bool* on = enabled == args->end()
                           ? nullptr
                           : std::get_if<bool>(&enabled->second);
      tray_enabled_ = on && *on;
      if (tray_enabled_) {
        AddTrayIcon();
      } else {
        RemoveTrayIcon();
        // Never leave the window hidden with no icon to bring it back.
        if (!IsWindowVisible(GetHandle())) {
          ShowFromTray();
        }
      }
      result->Success();
    } else if (call.method_name() == "getAutostart") {
      result->Success(flutter::EncodableValue(AutostartEnabled()));
    } else if (call.method_name() == "setAutostart") {
      // {enabled, inTray}
      const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
      auto flag = [args](const char* key) {
        if (!args) return false;
        auto it = args->find(flutter::EncodableValue(key));
        const bool* b =
            it == args->end() ? nullptr : std::get_if<bool>(&it->second);
        return b && *b;
      };
      if (!args) {
        result->Error("bad_args", "map expected");
      } else if (!SetAutostart(flag("enabled"), flag("inTray"))) {
        result->Error("registry", "Unable to change the startup entry");
      } else {
        result->Success();
      }
    } else {
      result->NotImplemented();
    }
  });
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  if (start_in_tray_) {
    // Started with Windows: only the icon until the user opens it. Dart
    // confirms (or turns off) the tray with setTray right after startup.
    tray_enabled_ = true;
    AddTrayIcon();
  }
  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    if (!start_in_tray_) {
      this->Show();
    }
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::ClearSecret() {
  // Only if the clipboard still holds the secret: nothing copied since.
  if (secret_clipboard_seq_ == 0 ||
      GetClipboardSequenceNumber() != secret_clipboard_seq_) {
    return;
  }
  if (OpenClipboard(GetHandle())) {
    EmptyClipboard();
    CloseClipboard();
    secret_clipboard_seq_ = 0;
  }
}

// static
UINT FlutterWindow::ShowMessage() {
  static const UINT message = RegisterWindowMessageW(L"Passlune.ShowWindow");
  return message;
}

void FlutterWindow::AddTrayIcon() {
  if (tray_added_ || !GetHandle()) {
    return;
  }
  NOTIFYICONDATAW nid{};
  nid.cbSize = sizeof(nid);
  nid.hWnd = GetHandle();
  nid.uID = kTrayId;
  nid.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP;
  nid.uCallbackMessage = kTrayMessage;
  nid.hIcon = static_cast<HICON>(LoadImageW(
      GetModuleHandle(nullptr), MAKEINTRESOURCEW(IDI_APP_ICON), IMAGE_ICON,
      GetSystemMetrics(SM_CXSMICON), GetSystemMetrics(SM_CYSMICON),
      LR_SHARED));
  wcsncpy_s(nid.szTip, L"Passlune", _TRUNCATE);
  tray_added_ = Shell_NotifyIconW(NIM_ADD, &nid) != FALSE;
}

void FlutterWindow::RemoveTrayIcon() {
  if (!tray_added_) {
    return;
  }
  NOTIFYICONDATAW nid{};
  nid.cbSize = sizeof(nid);
  nid.hWnd = GetHandle();
  nid.uID = kTrayId;
  Shell_NotifyIconW(NIM_DELETE, &nid);
  tray_added_ = false;
}

void FlutterWindow::ShowTrayHint() {
  // Once per run: the first close tells where the window went.
  if (hint_shown_ || !tray_added_) {
    return;
  }
  hint_shown_ = true;
  NOTIFYICONDATAW nid{};
  nid.cbSize = sizeof(nid);
  nid.hWnd = GetHandle();
  nid.uID = kTrayId;
  nid.uFlags = NIF_INFO;
  nid.dwInfoFlags = NIIF_INFO | NIIF_NOSOUND;
  wcsncpy_s(nid.szInfoTitle, hint_title_.c_str(), _TRUNCATE);
  wcsncpy_s(nid.szInfo, hint_text_.c_str(), _TRUNCATE);
  Shell_NotifyIconW(NIM_MODIFY, &nid);
}

void FlutterWindow::ShowFromTray() {
  HWND hwnd = GetHandle();
  if (!hwnd) {
    return;
  }
  if (!IsWindowVisible(hwnd)) {
    ShowWindow(hwnd, SW_SHOW);
  }
  if (IsIconic(hwnd)) {
    ShowWindow(hwnd, SW_RESTORE);
  }
  SetForegroundWindow(hwnd);
}

void FlutterWindow::ShowTrayMenu() {
  HWND hwnd = GetHandle();
  HMENU menu = CreatePopupMenu();
  if (!menu) {
    return;
  }
  AppendMenuW(menu, MF_STRING, kCmdOpen, label_open_.c_str());
  AppendMenuW(menu, MF_STRING, kCmdLock, label_lock_.c_str());
  AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  AppendMenuW(menu, MF_STRING, kCmdQuit, label_quit_.c_str());
  SetMenuDefaultItem(menu, kCmdOpen, FALSE);
  POINT pt;
  GetCursorPos(&pt);
  // Needed so the menu closes when the user clicks elsewhere.
  SetForegroundWindow(hwnd);
  UINT cmd = TrackPopupMenu(menu, TPM_RETURNCMD | TPM_RIGHTBUTTON | TPM_NONOTIFY,
                            pt.x, pt.y, 0, hwnd, nullptr);
  PostMessage(hwnd, WM_NULL, 0, 0);
  DestroyMenu(menu);
  switch (cmd) {
    case kCmdOpen:
      ShowFromTray();
      break;
    case kCmdLock:
      if (channel_) {
        channel_->InvokeMethod("trayLock", nullptr);
      }
      break;
    case kCmdQuit:
      quitting_ = true;
      PostMessage(hwnd, WM_CLOSE, 0, 0);
      break;
  }
}

void FlutterWindow::OnDestroy() {
  RemoveTrayIcon();
  // Closing the app within the 20 seconds must not leave a password behind.
  ClearSecret();
  channel_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Before Flutter: it treats WM_CLOSE as an exit request.
  static const UINT taskbar_created = RegisterWindowMessageW(L"TaskbarCreated");
  if (message == WM_CLOSE && tray_enabled_ && tray_added_ && !quitting_) {
    // Closing keeps Passlune in the notification area.
    ShowWindow(hwnd, SW_HIDE);
    ShowTrayHint();
    return 0;
  }
  if (message == kTrayMessage) {
    switch (LOWORD(lparam)) {
      case WM_LBUTTONUP:
      case WM_LBUTTONDBLCLK:
        ShowFromTray();
        break;
      case WM_RBUTTONUP:
      case WM_CONTEXTMENU:
        ShowTrayMenu();
        break;
    }
    return 0;
  }
  if (message == ShowMessage()) {
    // Passlune.exe started again: bring this one forward instead.
    ShowFromTray();
    return 0;
  }
  if (message == taskbar_created && tray_enabled_) {
    // Explorer restarted and lost the icon.
    tray_added_ = false;
    AddTrayIcon();
    return 0;
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
