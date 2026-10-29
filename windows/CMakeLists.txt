# Project-level configuration.
cmake_minimum_required(VERSION 3.14)
project(mpvson LANGUAGES CXX)

# The name of the executable created for the application. Change this to change
# the on-disk name of your application.
set(BINARY_NAME "mpvson")

# Explicitly opt in to modern CMake behaviors to avoid warnings with recent
# versions of CMake.
cmake_policy(VERSION 3.14...3.25)

# Define build configuration option.
get_property(IS_MULTICONFIG GLOBAL PROPERTY GENERATOR_IS_MULTI_CONFIG)
if(IS_MULTICONFIG)
  set(CMAKE_CONFIGURATION_TYPES "Debug;Profile;Release"
    CACHE STRING "" FORCE)
else()
  if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE "Debug" CACHE
      STRING "Flutter build mode" FORCE)
    set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS
      "Debug" "Profile" "Release")
  endif()
endif()
# Define settings for the Profile build mode.
set(CMAKE_EXE_LINKER_FLAGS_PROFILE "${CMAKE_EXE_LINKER_FLAGS_RELEASE}")
set(CMAKE_SHARED_LINKER_FLAGS_PROFILE "${CMAKE_SHARED_LINKER_FLAGS_RELEASE}")
set(CMAKE_C_FLAGS_PROFILE "${CMAKE_C_FLAGS_RELEASE}")
set(CMAKE_CXX_FLAGS_PROFILE "${CMAKE_CXX_FLAGS_RELEASE}")

# Use Unicode for all projects.
add_definitions(-DUNICODE -D_UNICODE)

# Compilation settings that should be applied to most targets.
#
# Be cautious about adding new options here, as plugins use this function by
# default. In most cases, you should add new options to specific targets instead
# of modifying this function.
function(APPLY_STANDARD_SETTINGS TARGET)
  target_compile_features(${TARGET} PUBLIC cxx_std_17)
  target_compile_options(${TARGET} PRIVATE /W4 /WX /wd"4100")
  target_compile_options(${TARGET} PRIVATE /EHsc)
  target_compile_definitions(${TARGET} PRIVATE "_HAS_EXCEPTIONS=0")
  target_compile_definitions(${TARGET} PRIVATE "$<$<CONFIG:Debug>:_DEBUG>")
endfunction()

# Flutter library and tool build rules.
set(FLUTTER_MANAGED_DIR "${CMAKE_CURRENT_SOURCE_DIR}/flutter")
add_subdirectory(${FLUTTER_MANAGED_DIR})

# Application build; see runner/CMakeLists.txt.
add_subdirectory("runner")


# Generated plugin build rules, which manage building the plugins and adding
# them to the application.
include(flutter/generated_plugins.cmake)

# The stock video plugin imports libmpv at process load time. Resolve its render
# API from the same explicitly selected module used by Dart instead, so a staged
# engine can live outside the application directory without mixing two engines.
if(TARGET media_kit_video_plugin)
  get_target_property(MPVSON_VIDEO_LIBRARIES media_kit_video_plugin LINK_LIBRARIES)
  list(FILTER MPVSON_VIDEO_LIBRARIES EXCLUDE REGEX "[/\\\\]libmpv\\.dll\\.a$")
  set_property(TARGET media_kit_video_plugin PROPERTY LINK_LIBRARIES "${MPVSON_VIDEO_LIBRARIES}")
  target_compile_definitions(media_kit_video_plugin PRIVATE MPV_CPLUGIN_DYNAMIC_SYM)
  target_sources(media_kit_video_plugin PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/engine_library_bridge.cpp")
endif()


# === Bundled engine ===
# The locked media_kit_libs_windows_video release ships a September 2023 mpv
# build (v0.36.0-403-g652a1dd907). mpv does not publish security fixes for
# releases that old, so the bundled fallback module below is replaced with the
# engine pinned in packaging/windows/engine-provenance.json. Every digest is
# checked before the module is copied next to the application. Staged engine
# packages from the update channel are unaffected by this step.
set(MPVSON_ENGINE_PROVENANCE
  "${CMAKE_CURRENT_SOURCE_DIR}/../packaging/windows/engine-provenance.json")
set(MPVSON_ENGINE_LICENSE
  "${CMAKE_CURRENT_SOURCE_DIR}/../packaging/windows/LICENSE.libmpv-GPL.txt")
if(NOT EXISTS "${MPVSON_ENGINE_PROVENANCE}")
  message(FATAL_ERROR "Mpvson engine record is missing: ${MPVSON_ENGINE_PROVENANCE}")
endif()
if(CMAKE_VERSION VERSION_LESS 3.19)
  message(FATAL_ERROR
    "Mpvson needs CMake 3.19 or newer to read ${MPVSON_ENGINE_PROVENANCE}. "
    "The installed version is ${CMAKE_VERSION}.")
endif()

file(READ "${MPVSON_ENGINE_PROVENANCE}" MPVSON_ENGINE_JSON)
string(JSON MPVSON_ENGINE_VERSION GET "${MPVSON_ENGINE_JSON}" engine version)
string(JSON MPVSON_ENGINE_ARTIFACT_URL GET "${MPVSON_ENGINE_JSON}" artifact url)
string(JSON MPVSON_ENGINE_ARTIFACT_NAME GET "${MPVSON_ENGINE_JSON}" artifact assetName)
string(JSON MPVSON_ENGINE_ARTIFACT_SIZE GET "${MPVSON_ENGINE_JSON}" artifact size)
string(JSON MPVSON_ENGINE_ARTIFACT_SHA GET "${MPVSON_ENGINE_JSON}" artifact sha256)
string(JSON MPVSON_ENGINE_MEMBER GET "${MPVSON_ENGINE_JSON}" artifact member)
string(JSON MPVSON_ENGINE_MEMBER_SIZE GET "${MPVSON_ENGINE_JSON}" artifact memberSize)
string(JSON MPVSON_ENGINE_MEMBER_SHA GET "${MPVSON_ENGINE_JSON}" artifact memberSha256)
string(JSON MPVSON_ENGINE_LICENSE_SHA GET "${MPVSON_ENGINE_JSON}" artifact licenseSha256)

file(SHA256 "${MPVSON_ENGINE_LICENSE}" MPVSON_ENGINE_LICENSE_LOCAL_SHA)
if(NOT MPVSON_ENGINE_LICENSE_LOCAL_SHA STREQUAL MPVSON_ENGINE_LICENSE_SHA)
  message(FATAL_ERROR
    "The bundled mpv license text does not match the pinned engine record.\n"
    "  file:     ${MPVSON_ENGINE_LICENSE}\n"
    "  expected: ${MPVSON_ENGINE_LICENSE_SHA}\n"
    "  actual:   ${MPVSON_ENGINE_LICENSE_LOCAL_SHA}")
endif()

set(MPVSON_ENGINE_CACHE_DIR "${CMAKE_BINARY_DIR}/engine")
set(MPVSON_ENGINE_ARTIFACT "${MPVSON_ENGINE_CACHE_DIR}/${MPVSON_ENGINE_ARTIFACT_NAME}")
set(MPVSON_ENGINE_CACHED_DLL
  "${MPVSON_ENGINE_CACHE_DIR}/${MPVSON_ENGINE_VERSION}/${MPVSON_ENGINE_MEMBER}")

# A pre-verified module can be supplied instead of downloading, which keeps
# offline builds and CI caches working.
set(MPVSON_ENGINE_DLL "" CACHE FILEPATH
  "Pre-verified ${MPVSON_ENGINE_MEMBER} to bundle. Empty selects the pinned package record.")

function(mpvson_engine_fail reason)
  message(FATAL_ERROR
    "Bundled engine ${MPVSON_ENGINE_VERSION} could not be prepared: ${reason}\n"
    "  pinned record: ${MPVSON_ENGINE_PROVENANCE}\n"
    "  pinned asset:  ${MPVSON_ENGINE_ARTIFACT_NAME}\n"
    "  cache:         ${MPVSON_ENGINE_CACHE_DIR}\n"
    "Refresh the pin after an intentional engine change:\n"
    "  dart run tool/engine_provenance.dart refresh --accept <version>\n"
    "Verify the record and the local cache:\n"
    "  dart run tool/engine_provenance.dart verify")
endfunction()

if(MPVSON_ENGINE_DLL)
  if(NOT EXISTS "${MPVSON_ENGINE_DLL}")
    mpvson_engine_fail("MPVSON_ENGINE_DLL points at '${MPVSON_ENGINE_DLL}', which does not exist.")
  endif()
  file(SHA256 "${MPVSON_ENGINE_DLL}" MPVSON_ENGINE_MODULE_SHA)
  if(NOT MPVSON_ENGINE_MODULE_SHA STREQUAL MPVSON_ENGINE_MEMBER_SHA)
    mpvson_engine_fail(
      "MPVSON_ENGINE_DLL '${MPVSON_ENGINE_DLL}' has SHA-256 "
      "${MPVSON_ENGINE_MODULE_SHA} instead of the pinned ${MPVSON_ENGINE_MEMBER_SHA}.")
  endif()
  set(MPVSON_ENGINE_MODULE "${MPVSON_ENGINE_DLL}")
  message(STATUS "Mpvson engine: using pre-verified ${MPVSON_ENGINE_MODULE}")
else()
  if(EXISTS "${MPVSON_ENGINE_ARTIFACT}")
    file(SHA256 "${MPVSON_ENGINE_ARTIFACT}" MPVSON_ENGINE_ARTIFACT_LOCAL_SHA)
    if(NOT MPVSON_ENGINE_ARTIFACT_LOCAL_SHA STREQUAL MPVSON_ENGINE_ARTIFACT_SHA)
      message(STATUS "Mpvson engine: discarding a cached archive with the wrong digest.")
      file(REMOVE "${MPVSON_ENGINE_ARTIFACT}")
    endif()
  endif()
  if(NOT EXISTS "${MPVSON_ENGINE_ARTIFACT}")
    message(STATUS
      "Mpvson engine: downloading ${MPVSON_ENGINE_ARTIFACT_NAME} "
      "(${MPVSON_ENGINE_VERSION})")
    set(MPVSON_ENGINE_DOWNLOAD_OPTIONS SHOW_PROGRESS TLS_VERIFY ON)
    if(CMAKE_VERSION VERSION_GREATER_EQUAL 3.27)
      list(APPEND MPVSON_ENGINE_DOWNLOAD_OPTIONS TIMEOUT 900)
    endif()
    file(MAKE_DIRECTORY "${MPVSON_ENGINE_CACHE_DIR}")
    file(DOWNLOAD "${MPVSON_ENGINE_ARTIFACT_URL}" "${MPVSON_ENGINE_ARTIFACT}"
      EXPECTED_HASH "SHA256=${MPVSON_ENGINE_ARTIFACT_SHA}"
      STATUS MPVSON_ENGINE_DOWNLOAD_STATUS
      ${MPVSON_ENGINE_DOWNLOAD_OPTIONS})
    list(GET MPVSON_ENGINE_DOWNLOAD_STATUS 0 MPVSON_ENGINE_DOWNLOAD_CODE)
    if(NOT MPVSON_ENGINE_DOWNLOAD_CODE EQUAL 0)
      list(GET MPVSON_ENGINE_DOWNLOAD_STATUS 1 MPVSON_ENGINE_DOWNLOAD_MESSAGE)
      file(REMOVE "${MPVSON_ENGINE_ARTIFACT}")
      mpvson_engine_fail(
        "download failed with code ${MPVSON_ENGINE_DOWNLOAD_CODE}: ${MPVSON_ENGINE_DOWNLOAD_MESSAGE}")
    endif()
  endif()
  file(SIZE "${MPVSON_ENGINE_ARTIFACT}" MPVSON_ENGINE_ARTIFACT_LOCAL_SIZE)
  if(NOT MPVSON_ENGINE_ARTIFACT_LOCAL_SIZE EQUAL MPVSON_ENGINE_ARTIFACT_SIZE)
    mpvson_engine_fail(
      "the cached archive holds ${MPVSON_ENGINE_ARTIFACT_LOCAL_SIZE} bytes instead of "
      "${MPVSON_ENGINE_ARTIFACT_SIZE}")
  endif()

  if(EXISTS "${MPVSON_ENGINE_CACHED_DLL}")
    file(SHA256 "${MPVSON_ENGINE_CACHED_DLL}" MPVSON_ENGINE_MODULE_SHA)
    if(NOT MPVSON_ENGINE_MODULE_SHA STREQUAL MPVSON_ENGINE_MEMBER_SHA)
      file(REMOVE_RECURSE "${MPVSON_ENGINE_CACHE_DIR}/${MPVSON_ENGINE_VERSION}")
    endif()
  endif()
  if(NOT EXISTS "${MPVSON_ENGINE_CACHED_DLL}")
    message(STATUS "Mpvson engine: extracting ${MPVSON_ENGINE_MEMBER}")
    file(REMOVE_RECURSE "${MPVSON_ENGINE_CACHE_DIR}/${MPVSON_ENGINE_VERSION}")
    file(ARCHIVE_EXTRACT
      INPUT "${MPVSON_ENGINE_ARTIFACT}"
      DESTINATION "${MPVSON_ENGINE_CACHE_DIR}/${MPVSON_ENGINE_VERSION}"
      PATTERNS "${MPVSON_ENGINE_MEMBER}")
    if(NOT EXISTS "${MPVSON_ENGINE_CACHED_DLL}")
      mpvson_engine_fail(
        "the archive did not contain ${MPVSON_ENGINE_MEMBER} at its root")
    endif()
  endif()
  file(SHA256 "${MPVSON_ENGINE_CACHED_DLL}" MPVSON_ENGINE_MODULE_SHA)
  if(NOT MPVSON_ENGINE_MODULE_SHA STREQUAL MPVSON_ENGINE_MEMBER_SHA)
    file(REMOVE "${MPVSON_ENGINE_CACHED_DLL}")
    mpvson_engine_fail(
      "the extracted module has SHA-256 ${MPVSON_ENGINE_MODULE_SHA} instead of the pinned "
      "${MPVSON_ENGINE_MEMBER_SHA}")
  endif()
  file(SIZE "${MPVSON_ENGINE_CACHED_DLL}" MPVSON_ENGINE_MODULE_SIZE)
  if(NOT MPVSON_ENGINE_MODULE_SIZE EQUAL MPVSON_ENGINE_MEMBER_SIZE)
    mpvson_engine_fail(
      "the extracted module holds ${MPVSON_ENGINE_MODULE_SIZE} bytes instead of "
      "${MPVSON_ENGINE_MEMBER_SIZE}")
  endif()
  set(MPVSON_ENGINE_MODULE "${MPVSON_ENGINE_CACHED_DLL}")
  message(STATUS
    "Mpvson engine: ${MPVSON_ENGINE_VERSION} verified "
    "(${MPVSON_ENGINE_MEMBER_SIZE} bytes, ${MPVSON_ENGINE_MEMBER_SHA})")
endif()

if(PLUGIN_BUNDLED_LIBRARIES)
  list(FILTER PLUGIN_BUNDLED_LIBRARIES EXCLUDE REGEX "[/\\\\]${MPVSON_ENGINE_MEMBER}$")
  list(APPEND PLUGIN_BUNDLED_LIBRARIES "${MPVSON_ENGINE_MODULE}")
endif()

# === Installation ===
# Support files are copied into place next to the executable, so that it can
# run in place. This is done instead of making a separate bundle (as on Linux)
# so that building and running from within Visual Studio will work.
set(BUILD_BUNDLE_DIR "$<TARGET_FILE_DIR:${BINARY_NAME}>")
# Make the "install" step default, as it's required to run.
set(CMAKE_VS_INCLUDE_INSTALL_TO_DEFAULT_BUILD 1)
set(CMAKE_INSTALL_PREFIX "${BUILD_BUNDLE_DIR}" CACHE PATH "..." FORCE)

set(INSTALL_BUNDLE_DATA_DIR "${CMAKE_INSTALL_PREFIX}/data")
set(INSTALL_BUNDLE_LIB_DIR "${CMAKE_INSTALL_PREFIX}")

install(TARGETS ${BINARY_NAME} RUNTIME DESTINATION "${CMAKE_INSTALL_PREFIX}"
  COMPONENT Runtime)

install(FILES
  "${CMAKE_CURRENT_SOURCE_DIR}/../packaging/windows/README.txt"
  "${CMAKE_CURRENT_SOURCE_DIR}/../packaging/windows/THIRD_PARTY.txt"
  DESTINATION "${CMAKE_INSTALL_PREFIX}" COMPONENT Runtime)
install(FILES "${MPVSON_ENGINE_PROVENANCE}"
  DESTINATION "${CMAKE_INSTALL_PREFIX}" COMPONENT Runtime
  RENAME "engine-provenance.json")
install(FILES "${MPVSON_ENGINE_LICENSE}"
  DESTINATION "${CMAKE_INSTALL_PREFIX}" COMPONENT Runtime
  RENAME "LICENSE.libmpv-GPL.txt")

install(FILES "${FLUTTER_ICU_DATA_FILE}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

if(PLUGIN_BUNDLED_LIBRARIES)
  install(FILES "${PLUGIN_BUNDLED_LIBRARIES}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endif()

# Copy the native assets provided by the build.dart from all packages.
set(NATIVE_ASSETS_DIR "${PROJECT_BUILD_DIR}native_assets/windows/")
install(DIRECTORY "${NATIVE_ASSETS_DIR}"
   DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
   COMPONENT Runtime)

# Fully re-copy the assets directory on each build to avoid having stale files
# from a previous install.
set(FLUTTER_ASSET_DIR_NAME "flutter_assets")
install(CODE "
  file(REMOVE_RECURSE \"${INSTALL_BUNDLE_DATA_DIR}/${FLUTTER_ASSET_DIR_NAME}\")
  " COMPONENT Runtime)
install(DIRECTORY "${PROJECT_BUILD_DIR}/${FLUTTER_ASSET_DIR_NAME}"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}" COMPONENT Runtime)

# Install the AOT library on non-Debug builds only.
install(FILES "${AOT_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  CONFIGURATIONS Profile;Release
  COMPONENT Runtime)
