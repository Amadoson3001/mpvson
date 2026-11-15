#ifndef RUNNER_GPU_INFO_H_
#define RUNNER_GPU_INFO_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>

#include <cstdint>
#include <memory>
#include <optional>

// Exposes read-only GPU diagnostics and the per-app Windows GPU preference
// through the "mpvson/gpu" method channel.
class GpuInfo {
 public:
  GpuInfo() = default;
  ~GpuInfo();

  GpuInfo(const GpuInfo&) = delete;
  GpuInfo& operator=(const GpuInfo&) = delete;

  void Initialize(flutter::BinaryMessenger* messenger);
  void CleanUp();
  void SetFlutterAdapterLuid(int64_t luid) { flutter_adapter_luid_ = luid; }

 private:
  void OnMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  std::optional<int64_t> flutter_adapter_luid_;
};

#endif  // RUNNER_GPU_INFO_H_
