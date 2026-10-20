#include <windows.h>
#include <client.h>
#include <render.h>

#include <string>

namespace {
HMODULE engine_module = nullptr;
std::wstring engine_path;

template <typename T>
bool Resolve(HMODULE module, const char* name, T& target) {
  target = reinterpret_cast<T>(GetProcAddress(module, name));
  return target != nullptr;
}
}  // namespace

// Called on the platform thread before any player or video output exists.
// Each process uses exactly one engine. Recovery after player initialization
// starts a fresh process because media_kit caches its native API bindings.
extern "C" __declspec(dllexport) int MpvsonConfigureEngine(const wchar_t* path) {
  if (path == nullptr || path[0] == L'\0') return ERROR_INVALID_PARAMETER;
  if (engine_module != nullptr) {
    return _wcsicmp(engine_path.c_str(), path) == 0 ? 0 : ERROR_ALREADY_INITIALIZED;
  }
  HMODULE module = LoadLibraryExW(path, nullptr,
      LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_DEFAULT_DIRS);
  if (module == nullptr) return static_cast<int>(GetLastError());

  bool valid = true;
#define RESOLVE_MPV(name) valid = Resolve(module, #name, pfn_##name) && valid
  RESOLVE_MPV(mpv_client_api_version);
  RESOLVE_MPV(mpv_set_option_string);
  RESOLVE_MPV(mpv_get_property);
  RESOLVE_MPV(mpv_free_node_contents);
  RESOLVE_MPV(mpv_render_context_create);
  RESOLVE_MPV(mpv_render_context_set_update_callback);
  RESOLVE_MPV(mpv_render_context_free);
  RESOLVE_MPV(mpv_render_context_render);
#undef RESOLVE_MPV
  if (!valid || (pfn_mpv_client_api_version() >> 16) != 2 ||
      pfn_mpv_client_api_version() < MPV_CLIENT_API_VERSION) {
    FreeLibrary(module);
    return ERROR_REVISION_MISMATCH;
  }
  engine_module = module;
  engine_path = path;
  return 0;
}

extern "C" __declspec(dllexport) const wchar_t* MpvsonEngineLibraryPath() {
  return engine_path.c_str();
}
