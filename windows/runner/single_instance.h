#ifndef RUNNER_SINGLE_INSTANCE_H_
#define RUNNER_SINGLE_INSTANCE_H_

#include <windows.h>
#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>

#include <atomic>
#include <memory>
#include <string>
#include <thread>
#include <vector>

constexpr UINT WM_SINGLE_INSTANCE_ACTIVATE = WM_USER + 101;

class SingleInstance {
 public:
  SingleInstance();
  ~SingleInstance();

  SingleInstance(const SingleInstance&) = delete;
  SingleInstance& operator=(const SingleInstance&) = delete;
  SingleInstance(SingleInstance&& other) noexcept;
  SingleInstance& operator=(SingleInstance&& other) noexcept;

  // Tries to acquire primary instance ownership or forwards arguments to the primary instance.
  // Returns true if this is the primary instance and execution should proceed.
  // Returns false if this is a secondary instance and has forwarded paths and brought the primary
  // window to the foreground (caller should exit with 0).
  bool AcquireOwnershipOrForward();

  // Initializes the named pipe server and MethodChannel on the primary instance.
  void Initialize(HWND window_handle, flutter::BinaryMessenger* messenger);

  // Handles activation posted to the main thread.
  void HandleActivate(const std::vector<std::string>& paths);

  // Cleans up resources, shuts down background server thread, and releases mutex.
  void CleanUp();

 private:
  void StartServer();
  void ServerThreadWorker();
  static void ForwardToPrimary(const std::vector<std::wstring>& raw_args);
  static std::vector<std::wstring> GetRawCommandLineArgs();
  static std::vector<std::string> ResolvePaths(const std::vector<std::wstring>& raw_args);

  HANDLE mutex_ = nullptr;
  HANDLE stop_event_ = nullptr;
  HWND window_handle_ = nullptr;
  std::thread server_thread_;
  std::atomic<bool> stopping_{false};

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};

#endif  // RUNNER_SINGLE_INSTANCE_H_
