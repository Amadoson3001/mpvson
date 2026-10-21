#ifndef RUNNER_POWER_MANAGEMENT_H_
#define RUNNER_POWER_MANAGEMENT_H_

#include <windows.h>

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>

#include <memory>

class PowerManagement {
 public:
  PowerManagement();
  ~PowerManagement();

  PowerManagement(const PowerManagement&) = delete;
  PowerManagement& operator=(const PowerManagement&) = delete;

  // Initializes the method channels for power management.
  void Initialize(flutter::BinaryMessenger* messenger);

  // Cleans up power requests and handles.
  void CleanUp();

  // Keep-awake controls
  void SetSystemKeepAwake(bool enable);
  void SetDisplayKeepAwake(bool enable);
  void Reset();

 private:
  void OnMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  HANDLE request_handle_ = INVALID_HANDLE_VALUE;
  bool system_awake_ = false;
  bool display_awake_ = false;

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> power_channel_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> management_channel_;
};

#endif  // RUNNER_POWER_MANAGEMENT_H_
