#ifndef RUNNER_ENGINE_BRIDGE_H_
#define RUNNER_ENGINE_BRIDGE_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>

#include <memory>

// Bridges the "mpvson/engine" method channel to the exported engine library
// bridge that lives inside the native video plugin.
//
// A process uses exactly one libmpv module, so it has to be selected before any
// player or video output is created. Both entry points are invoked by the
// Flutter engine on the platform thread.
class EngineBridge {
 public:
  EngineBridge() = default;
  ~EngineBridge();

  EngineBridge(const EngineBridge&) = delete;
  EngineBridge& operator=(const EngineBridge&) = delete;

  // Registers the method channel with |messenger|.
  void Initialize(flutter::BinaryMessenger* messenger);

  // Unregisters the method channel.
  void CleanUp();

 private:
  void OnMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};

#endif  // RUNNER_ENGINE_BRIDGE_H_
