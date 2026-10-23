#include "single_instance.h"

#include <flutter/standard_method_codec.h>
#include <shellapi.h>

#include <cstddef>
#include <utility>

#include "utils.h"

namespace {
constexpr size_t kMaxPipeMessageBytes = 1024 * 1024;
constexpr size_t kMaxForwardedPaths = 2048;
constexpr size_t kMaxForwardedPathBytes = 128 * 1024;
constexpr wchar_t kMutexName[] = L"Local\\Mpvson_SingleInstance_Mutex";
constexpr wchar_t kPipeName[] = L"\\\\.\\pipe\\Mpvson_SingleInstance_Pipe";
constexpr wchar_t kWindowClassName[] = L"FLUTTER_RUNNER_WIN32_WINDOW";
constexpr wchar_t kWindowTitle[] = L"Mpvson";
}  // namespace

SingleInstance::SingleInstance() = default;

SingleInstance::~SingleInstance() {
  CleanUp();
}

SingleInstance::SingleInstance(SingleInstance&& other) noexcept {
  *this = std::move(other);
}

SingleInstance& SingleInstance::operator=(SingleInstance&& other) noexcept {
  if (this != &other) {
    CleanUp();
    mutex_ = other.mutex_;
    other.mutex_ = nullptr;
    stop_event_ = other.stop_event_;
    other.stop_event_ = nullptr;
    window_handle_ = other.window_handle_;
    other.window_handle_ = nullptr;
    server_thread_ = std::move(other.server_thread_);
    stopping_.store(other.stopping_.load());
    channel_ = std::move(other.channel_);
  }
  return *this;
}

std::vector<std::wstring> SingleInstance::GetRawCommandLineArgs() {
  int argc = 0;
  wchar_t** argv = ::CommandLineToArgvW(::GetCommandLineW(), &argc);
  if (argv == nullptr) {
    return {};
  }
  std::vector<std::wstring> args;
  args.reserve(argc > 1 ? argc - 1 : 0);
  for (int i = 1; i < argc; ++i) {
    args.emplace_back(argv[i]);
  }
  ::LocalFree(argv);
  return args;
}

std::vector<std::string> SingleInstance::ResolvePaths(
    const std::vector<std::wstring>& raw_args) {
  std::vector<std::string> resolved;
  for (const auto& arg : raw_args) {
    if (arg.empty()) {
      continue;
    }
    // Skip command line flags/options
    if (arg[0] == L'-' || arg[0] == L'/') {
      continue;
    }
    // If it's a URL (http://, https://, rtsp://, file://, etc.), keep as-is
    if (arg.find(L"://") != std::wstring::npos) {
      resolved.push_back(Utf8FromUtf16(arg.c_str()));
      continue;
    }

    // Resolve relative path against current working directory
    DWORD needed = ::GetFullPathNameW(arg.c_str(), 0, nullptr, nullptr);
    if (needed > 0) {
      std::wstring full_path(needed, L'\0');
      if (::GetFullPathNameW(arg.c_str(), needed, full_path.data(), nullptr) > 0) {
        full_path.resize(wcslen(full_path.c_str()));
        resolved.push_back(Utf8FromUtf16(full_path.c_str()));
        continue;
      }
    }
    resolved.push_back(Utf8FromUtf16(arg.c_str()));
  }
  return resolved;
}

void SingleInstance::ForwardToPrimary(const std::vector<std::wstring>& raw_args) {
  std::vector<std::string> paths = ResolvePaths(raw_args);

  // Try connecting to the primary instance's named pipe
  HANDLE pipe = INVALID_HANDLE_VALUE;
  for (int attempt = 0; attempt < 20; ++attempt) {
    pipe = ::CreateFileW(
        kPipeName,
        GENERIC_WRITE,
        0,
        nullptr,
        OPEN_EXISTING,
        0,
        nullptr);

    if (pipe != INVALID_HANDLE_VALUE) {
      break;
    }

    if (::GetLastError() == ERROR_PIPE_BUSY) {
      ::WaitNamedPipeW(kPipeName, 1000);
    } else {
      ::Sleep(50);
    }
  }

  if (pipe != INVALID_HANDLE_VALUE) {
    // Send resolved paths separated by newline. Even if empty, write a newline
    // so the primary instance knows an activation occurred.
    std::string payload;
    for (const auto& path : paths) {
      if (path.size() > kMaxForwardedPathBytes ||
          payload.size() + path.size() + 1 > kMaxPipeMessageBytes) {
        ::CloseHandle(pipe);
        return;
      }
      payload += path;
      payload += '\n';
    }
    if (payload.empty()) {
      payload = "\n";
    }

    DWORD bytes_written = 0;
    ::WriteFile(pipe, payload.data(), static_cast<DWORD>(payload.size()),
                &bytes_written, nullptr);
    ::FlushFileBuffers(pipe);
    ::CloseHandle(pipe);
  }

  // Allow the primary instance to set its window as foreground
  ::AllowSetForegroundWindow(ASFW_ANY);

  // Find the primary instance window and bring it to foreground
  HWND hwnd = ::FindWindowW(kWindowClassName, nullptr);
  if (hwnd == nullptr) {
    hwnd = ::FindWindowW(nullptr, kWindowTitle);
  }
  if (hwnd != nullptr) {
    if (::IsIconic(hwnd)) {
      ::ShowWindow(hwnd, SW_RESTORE);
    }
    ::SetForegroundWindow(hwnd);
  }
}

bool SingleInstance::AcquireOwnershipOrForward() {
  std::vector<std::wstring> raw_args = GetRawCommandLineArgs();

  // Handover for engine recovery:
  // If command line contains '--engine-recovery', allow acquiring instance ownership.
  bool is_recovery = false;
  for (const auto& arg : raw_args) {
    if (arg.rfind(L"--engine-recovery", 0) == 0) {
      is_recovery = true;
      break;
    }
  }
  if (!is_recovery) {
    const wchar_t* cmd_line = ::GetCommandLineW();
    if (cmd_line != nullptr && wcsstr(cmd_line, L"--engine-recovery") != nullptr) {
      is_recovery = true;
    }
  }

  if (is_recovery) {
    // In recovery mode, wait for the exiting instance to release the mutex
    mutex_ = ::CreateMutexW(nullptr, FALSE, kMutexName);
    if (mutex_ != nullptr) {
      DWORD wait_result = ::WaitForSingleObject(mutex_, 10000);
      if (wait_result == WAIT_OBJECT_0 || wait_result == WAIT_ABANDONED) {
        return true;
      }
    }
    return true;
  }

  mutex_ = ::CreateMutexW(nullptr, TRUE, kMutexName);
  if (::GetLastError() == ERROR_ALREADY_EXISTS) {
    ForwardToPrimary(raw_args);
    if (mutex_ != nullptr) {
      ::CloseHandle(mutex_);
      mutex_ = nullptr;
    }
    return false;
  }

  return true;
}

void SingleInstance::Initialize(HWND window_handle,
                                flutter::BinaryMessenger* messenger) {
  window_handle_ = window_handle;

  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "mpvson/single_instance",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([](const auto& call, auto result) {
    result->NotImplemented();
  });

  StartServer();
}

void SingleInstance::StartServer() {
  if (server_thread_.joinable()) {
    return;
  }
  stopping_ = false;
  stop_event_ = ::CreateEventW(nullptr, TRUE, FALSE, nullptr);
  if (stop_event_ != nullptr) {
    server_thread_ = std::thread(&SingleInstance::ServerThreadWorker, this);
  }
}

void SingleInstance::ServerThreadWorker() {
  while (!stopping_) {
    HANDLE pipe = ::CreateNamedPipeW(
        kPipeName,
        PIPE_ACCESS_INBOUND | FILE_FLAG_OVERLAPPED,
        PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT,
        PIPE_UNLIMITED_INSTANCES,
        4096,
        4096,
        0,
        nullptr);

    if (pipe == INVALID_HANDLE_VALUE) {
      ::Sleep(200);
      continue;
    }

    OVERLAPPED overlap = {};
    overlap.hEvent = ::CreateEventW(nullptr, TRUE, FALSE, nullptr);
    if (overlap.hEvent == nullptr) {
      ::CloseHandle(pipe);
      ::Sleep(200);
      continue;
    }

    BOOL connected = ::ConnectNamedPipe(pipe, &overlap);
    DWORD connect_error = connected ? ERROR_SUCCESS : ::GetLastError();
    if (!connected && connect_error == ERROR_PIPE_CONNECTED) {
      connected = TRUE;
    }

    if (!connected && connect_error == ERROR_IO_PENDING) {
      HANDLE events[2] = {stop_event_, overlap.hEvent};
      DWORD wait = ::WaitForMultipleObjects(2, events, FALSE, INFINITE);
      if (wait == WAIT_OBJECT_0) {
        // Stopping
        ::CancelIoEx(pipe, &overlap);
        DWORD ignored = 0;
        ::GetOverlappedResult(pipe, &overlap, &ignored, TRUE);
        ::CloseHandle(overlap.hEvent);
        ::CloseHandle(pipe);
        break;
      } else if (wait == WAIT_OBJECT_0 + 1) {
        DWORD ignored = 0;
        connected = ::GetOverlappedResult(pipe, &overlap, &ignored, FALSE);
      } else {
        ::CancelIoEx(pipe, &overlap);
        DWORD ignored = 0;
        ::GetOverlappedResult(pipe, &overlap, &ignored, TRUE);
      }
    }
    ::CloseHandle(overlap.hEvent);

    if (connected && !stopping_) {
      std::string data;
      char buffer[1024];
      bool valid_message = true;
      while (!stopping_) {
        OVERLAPPED read_overlap = {};
        read_overlap.hEvent = ::CreateEventW(nullptr, TRUE, FALSE, nullptr);
        if (read_overlap.hEvent == nullptr) {
          valid_message = false;
          break;
        }
        DWORD bytes_read = 0;
        BOOL read_ok = ::ReadFile(pipe, buffer, sizeof(buffer), &bytes_read,
                                  &read_overlap);
        DWORD read_error = read_ok ? ERROR_SUCCESS : ::GetLastError();
        if (!read_ok && read_error == ERROR_IO_PENDING) {
          HANDLE events[2] = {stop_event_, read_overlap.hEvent};
          const DWORD wait =
              ::WaitForMultipleObjects(2, events, FALSE, INFINITE);
          if (wait == WAIT_OBJECT_0) {
            ::CancelIoEx(pipe, &read_overlap);
            ::GetOverlappedResult(pipe, &read_overlap, &bytes_read, TRUE);
            ::CloseHandle(read_overlap.hEvent);
            valid_message = false;
            break;
          }
          if (wait != WAIT_OBJECT_0 + 1) {
            ::CancelIoEx(pipe, &read_overlap);
            ::GetOverlappedResult(pipe, &read_overlap, &bytes_read, TRUE);
            ::CloseHandle(read_overlap.hEvent);
            valid_message = false;
            break;
          }
          if (!::GetOverlappedResult(pipe, &read_overlap, &bytes_read, FALSE)) {
            read_error = ::GetLastError();
            ::CloseHandle(read_overlap.hEvent);
            if (read_error != ERROR_BROKEN_PIPE && !stopping_) {
              valid_message = false;
            }
            break;
          }
        } else if (!read_ok) {
          ::CloseHandle(read_overlap.hEvent);
          if (read_error != ERROR_BROKEN_PIPE) valid_message = false;
          break;
        }
        ::CloseHandle(read_overlap.hEvent);
        if (bytes_read == 0) break;
        if (data.size() + bytes_read > kMaxPipeMessageBytes) {
          valid_message = false;
          break;
        }
        data.append(buffer, bytes_read);
      }

      ::DisconnectNamedPipe(pipe);
      ::CloseHandle(pipe);

      auto paths = std::make_unique<std::vector<std::string>>();
      size_t start = 0;
      while (valid_message && start < data.size()) {
        size_t end = data.find('\n', start);
        if (end == std::string::npos) {
          std::string line = data.substr(start);
          if (line.size() > kMaxForwardedPathBytes ||
              paths->size() >= kMaxForwardedPaths) {
            valid_message = false;
          } else if (!line.empty()) {
            paths->push_back(std::move(line));
          }
          break;
        }
        std::string line = data.substr(start, end - start);
        if (line.size() > kMaxForwardedPathBytes ||
            paths->size() >= kMaxForwardedPaths) {
          valid_message = false;
          break;
        }
        if (!line.empty()) paths->push_back(std::move(line));
        start = end + 1;
      }

      if (valid_message && window_handle_ != nullptr && !stopping_) {
        auto* posted_paths = paths.get();
        if (::PostMessageW(window_handle_, WM_SINGLE_INSTANCE_ACTIVATE, 0,
                           reinterpret_cast<LPARAM>(posted_paths))) {
          paths.release();
        }
      }
    } else {
      ::CloseHandle(pipe);
    }
  }
}

void SingleInstance::HandleActivate(const std::vector<std::string>& paths) {
  if (window_handle_ != nullptr) {
    if (::IsIconic(window_handle_)) {
      ::ShowWindow(window_handle_, SW_RESTORE);
    }
    ::SetForegroundWindow(window_handle_);
  }

  if (channel_ != nullptr) {
    flutter::EncodableList list;
    list.reserve(paths.size());
    for (const auto& path : paths) {
      list.emplace_back(flutter::EncodableValue(path));
    }
    channel_->InvokeMethod("onActivate",
                           std::make_unique<flutter::EncodableValue>(list));
  }
}

void SingleInstance::CleanUp() {
  stopping_ = true;
  if (stop_event_ != nullptr) {
    ::SetEvent(stop_event_);
  }
  if (server_thread_.joinable()) {
    server_thread_.join();
  }
  if (stop_event_ != nullptr) {
    ::CloseHandle(stop_event_);
    stop_event_ = nullptr;
  }
  if (mutex_ != nullptr) {
    ::CloseHandle(mutex_);
    mutex_ = nullptr;
  }
  channel_ = nullptr;
  window_handle_ = nullptr;
}
