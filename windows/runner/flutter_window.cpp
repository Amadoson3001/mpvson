#include "flutter_window.h"

#include <optional>
#include <flutter/standard_method_codec.h>

#include "flutter/generated_plugin_registrant.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project,
                             std::unique_ptr<SingleInstance> single_instance)
    : project_(project), single_instance_(std::move(single_instance)) {}

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

  auto* messenger = flutter_controller_->engine()->messenger();
  HWND hwnd = GetHandle();

  // Initialize native integrations
  if (single_instance_) {
    single_instance_->Initialize(hwnd, messenger);
  }

  system_media_transport_ = std::make_unique<SystemMediaTransport>();
  system_media_transport_->Initialize(hwnd, messenger);

  power_management_ = std::make_unique<PowerManagement>();
  power_management_->Initialize(messenger);

  engine_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "mpvson/engine",
      &flutter::StandardMethodCodec::GetInstance());
  engine_channel_->SetMethodCallHandler([](const auto& call, auto result) {
    const auto module = GetModuleHandleW(L"media_kit_video_plugin.dll");
    if (module == nullptr) {
      result->Error("engine_bridge", "The native video engine bridge is unavailable.");
      return;
    }
    if (call.method_name() == "configure") {
      const auto path = call.arguments() == nullptr
          ? nullptr : std::get_if<std::string>(call.arguments());
      if (path == nullptr || path->empty()) {
        result->Error("engine_path", "An absolute engine library path is required.");
        return;
      }
      const int length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
          path->data(), static_cast<int>(path->size()), nullptr, 0);
      if (length <= 0) {
        result->Error("engine_path", "The engine library path is not valid UTF-8.");
        return;
      }
      std::wstring wide_path(length, L'\0');
      MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path->data(),
          static_cast<int>(path->size()), wide_path.data(), length);
      using Configure = int (*)(const wchar_t*);
      const auto configure = reinterpret_cast<Configure>(
          GetProcAddress(module, "MpvsonConfigureEngine"));
      const int code = configure == nullptr ? ERROR_PROC_NOT_FOUND : configure(wide_path.c_str());
      if (code != 0) {
        result->Error("engine_load", "Could not load the selected native engine. Windows error " + std::to_string(code));
        return;
      }
      result->Success();
    } else if (call.method_name() == "libraryPath") {
      using LibraryPath = const wchar_t* (*)();
      const auto library_path = reinterpret_cast<LibraryPath>(
          GetProcAddress(module, "MpvsonEngineLibraryPath"));
      const auto path = library_path == nullptr ? L"" : library_path();
      const int length = WideCharToMultiByte(CP_UTF8, 0, path, -1,
          nullptr, 0, nullptr, nullptr);
      std::string value(length > 0 ? length : 1, '\0');
      if (length > 0) WideCharToMultiByte(CP_UTF8, 0, path, -1,
          value.data(), length, nullptr, nullptr);
      value.resize(value.size() - 1);
      result->Success(flutter::EncodableValue(value));
    } else {
      result->NotImplemented();
    }
  });
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (power_management_) {
    power_management_->CleanUp();
    power_management_ = nullptr;
  }
  if (system_media_transport_) {
    system_media_transport_->CleanUp();
    system_media_transport_ = nullptr;
  }
  if (single_instance_) {
    single_instance_->CleanUp();
    MSG pending = {};
    while (::PeekMessageW(&pending, GetHandle(), WM_SINGLE_INSTANCE_ACTIVATE,
                          WM_SINGLE_INSTANCE_ACTIVATE, PM_REMOVE)) {
      delete reinterpret_cast<std::vector<std::string>*>(pending.lParam);
    }
    single_instance_ = nullptr;
  }

  engine_channel_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
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
    case WM_SINGLE_INSTANCE_ACTIVATE: {
      std::unique_ptr<std::vector<std::string>> paths(
          reinterpret_cast<std::vector<std::string>*>(lparam));
      if (single_instance_ && paths != nullptr) {
        single_instance_->HandleActivate(*paths);
      }
      return 0;
    }
    case WM_SMTC_BUTTON_PRESS:
      if (system_media_transport_) {
        system_media_transport_->HandleButtonPress(static_cast<int>(wparam));
      }
      return 0;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
