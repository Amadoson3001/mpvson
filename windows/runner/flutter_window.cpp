#include "flutter_window.h"

#include <optional>

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

  engine_bridge_ = std::make_unique<EngineBridge>();
  engine_bridge_->Initialize(messenger);

  system_media_transport_ = std::make_unique<SystemMediaTransport>();
  system_media_transport_->Initialize(hwnd, messenger);

  power_management_ = std::make_unique<PowerManagement>();
  power_management_->Initialize(messenger);

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
  if (single_instance_) {
    single_instance_->CleanUp();
    MSG pending = {};
    while (::PeekMessageW(&pending, GetHandle(), WM_SINGLE_INSTANCE_ACTIVATE,
                          WM_SINGLE_INSTANCE_ACTIVATE, PM_REMOVE)) {
      delete reinterpret_cast<std::vector<std::string>*>(pending.lParam);
    }
    single_instance_ = nullptr;
  }
  if (engine_bridge_) {
    engine_bridge_->CleanUp();
    engine_bridge_ = nullptr;
  }
  if (system_media_transport_) {
    system_media_transport_->CleanUp();
    system_media_transport_ = nullptr;
  }
  if (power_management_) {
    power_management_->CleanUp();
    power_management_ = nullptr;
  }
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
      // The controller is torn down in OnDestroy, which can still be followed
      // by further messages for the window being destroyed.
      if (flutter_controller_) {
        flutter_controller_->engine()->ReloadSystemFonts();
      }
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
    case WM_SMTC_THUMBNAIL:
      if (system_media_transport_) {
        system_media_transport_->ApplyThumbnail(static_cast<uint64_t>(wparam),
                                                reinterpret_cast<void*>(lparam));
      } else {
        SystemMediaTransport::ReleaseThumbnail(reinterpret_cast<void*>(lparam));
      }
      return 0;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
