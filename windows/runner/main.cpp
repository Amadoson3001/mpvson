#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <string>
#include <vector>

#include "flutter_window.h"
#include "single_instance.h"
#include "utils.h"

namespace {

void WriteCliOutput(const std::string& text) {
  HANDLE std_out = ::GetStdHandle(STD_OUTPUT_HANDLE);
  DWORD file_type =
      (std_out != nullptr && std_out != INVALID_HANDLE_VALUE)
          ? ::GetFileType(std_out)
          : FILE_TYPE_UNKNOWN;
  if (file_type == FILE_TYPE_PIPE ||
      file_type == FILE_TYPE_DISK ||
      file_type == FILE_TYPE_CHAR) {
    DWORD written = 0;
    ::WriteFile(std_out, text.data(), static_cast<DWORD>(text.size()),
                &written, nullptr);
    if (file_type == FILE_TYPE_DISK) {
      ::FlushFileBuffers(std_out);
    }
    return;
  }

  if (::AttachConsole(ATTACH_PARENT_PROCESS)) {
    HANDLE con_out = ::CreateFileW(
        L"CONOUT$", GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE,
        nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (con_out != INVALID_HANDLE_VALUE) {
      DWORD written = 0;
      ::WriteFile(con_out, text.data(), static_cast<DWORD>(text.size()),
                  &written, nullptr);
      ::CloseHandle(con_out);
    }
    ::FreeConsole();
  }
}

std::string GetMpvsonCliVersion() {
#ifdef FLUTTER_VERSION
  std::string version(FLUTTER_VERSION);
#else
  std::string version("0.1.0");
#endif
  const size_t plus_pos = version.find('+');
  if (plus_pos != std::string::npos) {
    version.resize(plus_pos);
  }
  return version;
}

bool HandleEarlyCliCommand(const std::vector<std::string>& args) {
  bool show_help = false;
  bool show_version = false;
  for (const auto& arg : args) {
    if (arg == "--") {
      break;
    }
    if (arg == "--help" || arg == "-h" || arg == "/?") {
      show_help = true;
    } else if (arg == "--version" || arg == "-v") {
      show_version = true;
    }
  }
  if (show_help) {
    WriteCliOutput(
        "Mpvson - desktop media player\n\n"
        "Usage:\n"
        "  mpvson [options] [files or URLs...]\n\n"
        "Options:\n"
        "  -e, --enqueue   Append items to the active playback queue\n"
        "  -v, --version   Print version information and exit\n"
        "  -h, --help      Print this help message and exit\n"
        "      --          Treat all remaining arguments as files or URLs\n");
    return true;
  }
  if (show_version) {
    WriteCliOutput("Mpvson " + GetMpvsonCliVersion() + "\n");
    return true;
  }
  return false;
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();
  if (HandleEarlyCliCommand(command_line_arguments)) {
    return EXIT_SUCCESS;
  }

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Single Instance check:
  // If secondary instance, resolve relative paths against current working directory,
  // send paths to named pipe, bring main window to foreground, and exit with 0.
  auto single_instance = std::make_unique<SingleInstance>();
  if (!single_instance->AcquireOwnershipOrForward()) {
    return EXIT_SUCCESS;
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  // On cold process startup, clear any stale NativeReferenceHolder file that
  // might exist if the OS reused a PID from a previously dead process.
  wchar_t temp_dir[MAX_PATH];
  if (::GetTempPathW(MAX_PATH, temp_dir)) {
    wchar_t holder_file[MAX_PATH];
    swprintf_s(holder_file, MAX_PATH,
               L"%scom.alexmercerind.media_kit.NativeReferenceHolder.%lu",
               temp_dir, ::GetCurrentProcessId());
    ::DeleteFileW(holder_file);
  }

  flutter::DartProject project(L"data");

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));
  // Impeller's Windows compositor stutters DXGI shared-handle video textures
  // even on discrete GPUs. Skia/ANGLE keeps the media_kit present path.
  project.set_impeller_switch(flutter::ImpellerSwitch::Disabled);
  // Prefer the discrete GPU so Flutter's compositor and the video renderer
  // stay on the same adapter on hybrid laptops.
  project.set_gpu_preference(
      flutter::GpuPreference::HighPerformancePreference);

  FlutterWindow window(project, std::move(single_instance));
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"Mpvson", origin, size)) {
    ::CoUninitialize();
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
