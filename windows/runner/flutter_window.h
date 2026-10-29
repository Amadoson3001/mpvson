#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/encodable_value.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>

#include <memory>

#include "engine_bridge.h"
#include "power_management.h"
#include "single_instance.h"
#include "system_media_transport.h"
#include "win32_window.h"

// A window that hosts a Flutter view and integrates Windows native platform capabilities.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project,
                         std::unique_ptr<SingleInstance> single_instance = nullptr);
  virtual ~FlutterWindow();

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

  // Native integration modules
  std::unique_ptr<EngineBridge> engine_bridge_;
  std::unique_ptr<SingleInstance> single_instance_;
  std::unique_ptr<SystemMediaTransport> system_media_transport_;
  std::unique_ptr<PowerManagement> power_management_;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
