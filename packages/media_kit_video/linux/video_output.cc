// This file is a part of media_kit
// (https://github.com/media-kit/media-kit).
//
// Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
// All rights reserved.
// Use of this source code is governed by MIT license that can be found in the
// LICENSE file.

#include "include/media_kit_video/video_output.h"
#include "include/media_kit_video/texture_gl.h"
#include "include/media_kit_video/texture_sw.h"

#include <algorithm>
#include <cmath>
#include <epoxy/egl.h>
#include <epoxy/glx.h>
#include <gdk/gdkwayland.h>
#include <gdk/gdkx.h>
#include <utility>

static std::pair<gint64, gint64> fit_software_dimensions(
    gint64 width, gint64 height) {
  if (width <= 0 || height <= 0) return {width, height};
  const double scale = (std::min)(
      {1.0, static_cast<double>(SW_RENDERING_MAX_WIDTH) / width,
       static_cast<double>(SW_RENDERING_MAX_HEIGHT) / height});
  return {
      (std::max<gint64>)(
          1, static_cast<gint64>(std::floor(width * scale))),
      (std::max<gint64>)(
          1, static_cast<gint64>(std::floor(height * scale))),
  };
}

struct _VideoOutput {
  GObject parent_instance;
  TextureGL* texture_gl;
  gboolean texture_gl_registered;
  EGLDisplay egl_display; /* EGL display for mpv rendering (shared with flutter). */
  EGLContext egl_context; /* Isolated EGL context (non-shared). */
  EGLSurface egl_surface; /* Place holder surface for activating egl context */
  EGLDisplay flutter_egl_display;
  EGLContext flutter_egl_context;
  EGLSurface flutter_egl_draw_surface;
  EGLSurface flutter_egl_read_surface;
  guint8* pixel_buffer;
  TextureSW* texture_sw;
  gboolean texture_sw_registered;
  GMutex mutex; /* Only used in S/W rendering. */
  GMutex render_source_mutex; /* Protects the queued GLib idle source ID. */
  guint render_source_id;
  GRecMutex render_mutex; /* Serializes the isolated EGL context and teardown. */
  mpv_handle* handle;
  mpv_render_context* render_context;
  gint64 width;
  gint64 height;
  VideoOutputConfiguration configuration;
  TextureUpdateCallback texture_update_callback;
  gpointer texture_update_callback_context;
  GDestroyNotify texture_update_callback_context_destroy_notify;
  FlTextureRegistrar* texture_registrar;
  gint destroyed;
  gint visible;
};

static GQuark video_output_error_quark() {
  return g_quark_from_static_string("media-kit-video-output-error");
}

// A failed hardware context can be current after TextureGL disposal binds it
// to release mpv's GL objects. Restore Flutter's context, or unbind it, before
// starting software rendering. Keep the handle if EGL refuses destruction so
// teardown can retry without ever destroying a context that is still current.
static gboolean release_egl_context(VideoOutput* self,
                                    const gchar* operation) {
  if (self->egl_context == EGL_NO_CONTEXT) return TRUE;

  if (eglGetCurrentContext() == self->egl_context) {
    gboolean restored_flutter_context =
        self->flutter_egl_display != EGL_NO_DISPLAY &&
        self->flutter_egl_context != EGL_NO_CONTEXT &&
        eglMakeCurrent(self->flutter_egl_display,
                       self->flutter_egl_draw_surface,
                       self->flutter_egl_read_surface,
                       self->flutter_egl_context);
    if (!restored_flutter_context) {
      g_warning(
          "media_kit: Could not restore Flutter's EGL context %s (EGL error "
          "0x%x); attempting to unbind the failed context.",
          operation, eglGetError());
      if (!eglMakeCurrent(self->egl_display, EGL_NO_SURFACE, EGL_NO_SURFACE,
                          EGL_NO_CONTEXT)) {
        g_warning("media_kit: Could not unbind the EGL context %s (EGL error "
                  "0x%x).",
                  operation, eglGetError());
      }
    }
  }

  if (eglGetCurrentContext() == self->egl_context) {
    g_warning("media_kit: The failed EGL context is still current %s; it will "
              "not be destroyed.",
              operation);
    return FALSE;
  }

  if (eglDestroyContext(self->egl_display, self->egl_context)) {
    self->egl_context = EGL_NO_CONTEXT;
  } else {
    g_warning("media_kit: Could not destroy the EGL context %s (EGL error "
              "0x%x).",
              operation, eglGetError());
  }
  return TRUE;
}

G_DEFINE_TYPE(VideoOutput, video_output, G_TYPE_OBJECT)

static void video_output_dispose(GObject* object) {
  VideoOutput* self = VIDEO_OUTPUT(object);
  video_output_shutdown(self);

  // Unregister outside the render lock: the registrar may wait for an active
  // Flutter texture callback, which also needs that lock to finish.
  if (self->texture_gl && self->texture_gl_registered) {
    fl_texture_registrar_unregister_texture(self->texture_registrar,
                                            FL_TEXTURE(self->texture_gl));
    self->texture_gl_registered = FALSE;
  }
  if (self->texture_sw && self->texture_sw_registered) {
    fl_texture_registrar_unregister_texture(self->texture_registrar,
                                            FL_TEXTURE(self->texture_sw));
    self->texture_sw_registered = FALSE;
  }
  if (self->texture_update_callback_context_destroy_notify != NULL) {
    GDestroyNotify destroy_notify =
        self->texture_update_callback_context_destroy_notify;
    gpointer context = self->texture_update_callback_context;
    self->texture_update_callback_context_destroy_notify = NULL;
    self->texture_update_callback_context = NULL;
    destroy_notify(context);
  }
  g_rec_mutex_lock(&self->render_mutex);

  // H/W
  if (self->texture_gl) {
    // Save Flutter's current context before cleanup
    EGLDisplay current_display = eglGetCurrentDisplay();
    EGLContext flutter_context = eglGetCurrentContext();
    EGLSurface flutter_draw_surface = eglGetCurrentSurface(EGL_DRAW);
    EGLSurface flutter_read_surface = eglGetCurrentSurface(EGL_READ);
    
    // Free mpv_render_context with our own isolated EGL context.
    if (self->render_context != NULL) {
      if (self->egl_context != EGL_NO_CONTEXT &&
          eglMakeCurrent(self->egl_display, EGL_NO_SURFACE, EGL_NO_SURFACE,
                         self->egl_context)) {
        mpv_render_context_free(self->render_context);
        self->render_context = NULL;
      } else {
        // Freeing an OpenGL render context while a different context is current
        // can delete unrelated GL objects. The EGL context destruction below
        // reclaims its GL resources when a context switch is no longer possible.
        g_warning("media_kit: Could not make the mpv EGL context current during teardown; skipping mpv render-context cleanup.");
      }
      
      // Restore Flutter's context
      if (flutter_context != EGL_NO_CONTEXT) {
        if (!eglMakeCurrent(current_display, flutter_draw_surface,
                            flutter_read_surface, flutter_context)) {
          g_warning("media_kit: Could not restore the EGL context after mpv teardown.");
          eglMakeCurrent(self->egl_display, EGL_NO_SURFACE, EGL_NO_SURFACE,
                         EGL_NO_CONTEXT);
        }
      } else {
        if (!eglMakeCurrent(self->egl_display, EGL_NO_SURFACE, EGL_NO_SURFACE,
                            EGL_NO_CONTEXT)) {
          g_warning("media_kit: Could not unbind the EGL context after mpv teardown.");
        }
      }
    }
    
    // Texture cleanup also uses the context. Release it before destroying EGL.
    g_object_unref(self->texture_gl);
    self->texture_gl = NULL;

  }
  if (self->egl_context != EGL_NO_CONTEXT) {
    release_egl_context(self, "during teardown");
  }
  // S/W
  if (self->texture_sw) {
    g_free(self->pixel_buffer);
    self->pixel_buffer = NULL;
    g_object_unref(self->texture_sw);
    self->texture_sw = NULL;
    if (self->render_context != NULL) {
      mpv_render_context_free(self->render_context);
      self->render_context = NULL;
    }
  }
  
  g_rec_mutex_unlock(&self->render_mutex);
  G_OBJECT_CLASS(video_output_parent_class)->dispose(object);
}

static void video_output_finalize(GObject* object) {
  VideoOutput* self = VIDEO_OUTPUT(object);
  g_mutex_clear(&self->mutex);
  g_mutex_clear(&self->render_source_mutex);
  g_rec_mutex_clear(&self->render_mutex);
  G_OBJECT_CLASS(video_output_parent_class)->finalize(object);
}

static void video_output_class_init(VideoOutputClass* klass) {
  G_OBJECT_CLASS(klass)->dispose = video_output_dispose;
  G_OBJECT_CLASS(klass)->finalize = video_output_finalize;
}

static void video_output_init(VideoOutput* self) {
  self->texture_gl = NULL;
  self->texture_gl_registered = FALSE;
  self->egl_display = EGL_NO_DISPLAY;
  self->egl_context = EGL_NO_CONTEXT;
  self->egl_surface = EGL_NO_SURFACE;
  self->flutter_egl_display = EGL_NO_DISPLAY;
  self->flutter_egl_context = EGL_NO_CONTEXT;
  self->flutter_egl_draw_surface = EGL_NO_SURFACE;
  self->flutter_egl_read_surface = EGL_NO_SURFACE;
  self->texture_sw = NULL;
  self->texture_sw_registered = FALSE;
  self->pixel_buffer = NULL;
  self->handle = NULL;
  self->render_context = NULL;
  self->width = 0;
  self->height = 0;
  self->configuration = VideoOutputConfiguration{};
  self->texture_update_callback = NULL;
  self->texture_update_callback_context = NULL;
  self->texture_update_callback_context_destroy_notify = NULL;
  self->texture_registrar = NULL;
  g_atomic_int_set(&self->destroyed, 0);
  g_atomic_int_set(&self->visible, 1);
  self->render_source_id = 0;
  g_mutex_init(&self->mutex);
  g_mutex_init(&self->render_source_mutex);
  g_rec_mutex_init(&self->render_mutex);
}

void video_output_lock_render(VideoOutput* self) {
  g_rec_mutex_lock(&self->render_mutex);
}

void video_output_unlock_render(VideoOutput* self) {
  g_rec_mutex_unlock(&self->render_mutex);
}

gboolean video_output_is_destroyed(VideoOutput* self) {
  return g_atomic_int_get(&self->destroyed) != 0;
}

void video_output_shutdown(VideoOutput* self) {
  if (!g_atomic_int_compare_and_exchange(&self->destroyed, 0, 1)) return;
  // Do not hold the render lock while waiting for mpv's callback to return.
  if (self->render_context != NULL) {
    mpv_render_context_set_update_callback(self->render_context, NULL, NULL);
  }

  // The source owns a reference to |self|. Remove it while the manager still
  // owns the output so the source's destroy notify cannot defer final disposal
  // until after the texture registrar has gone away. Do not hold the source
  // mutex during g_source_remove(): its destroy notify may unref |self|.
  g_mutex_lock(&self->render_source_mutex);
  const guint source_id = self->render_source_id;
  self->render_source_id = 0;
  g_mutex_unlock(&self->render_source_mutex);
  if (source_id != 0) g_source_remove(source_id);
}

static gboolean video_output_render_idle(gpointer data) {
  VideoOutput* self = VIDEO_OUTPUT(data);
  // Scheduling holds this mutex until g_idle_add_full returns its ID, so an
  // immediately dispatched callback cannot clear a stale/uninitialized ID.
  g_mutex_lock(&self->render_source_mutex);
  self->render_source_id = 0;
  g_mutex_unlock(&self->render_source_mutex);
  video_output_lock_render(self);
  if (video_output_is_destroyed(self)) {
    video_output_unlock_render(self);
    return G_SOURCE_REMOVE;
  }
  if (self->texture_gl != NULL) {
    if (video_output_get_visibility(self)) {
      fl_texture_registrar_mark_texture_frame_available(
          self->texture_registrar, FL_TEXTURE(self->texture_gl));
    } else if (self->render_context != NULL &&
               self->egl_context != EGL_NO_CONTEXT) {
      const EGLDisplay old_display = eglGetCurrentDisplay();
      const EGLContext old_context = eglGetCurrentContext();
      const EGLSurface old_draw = eglGetCurrentSurface(EGL_DRAW);
      const EGLSurface old_read = eglGetCurrentSurface(EGL_READ);
      if (eglMakeCurrent(self->egl_display, EGL_NO_SURFACE, EGL_NO_SURFACE,
                         self->egl_context)) {
        int skip = 1;
        mpv_render_param params[] = {
            {MPV_RENDER_PARAM_SKIP_RENDERING, &skip},
            {MPV_RENDER_PARAM_INVALID, NULL},
        };
        mpv_render_context_render(self->render_context, params);
        if (old_context != EGL_NO_CONTEXT) {
          eglMakeCurrent(old_display, old_draw, old_read, old_context);
        } else {
          // An idle callback normally has no current context. Always unbind
          // ours so Flutter's raster thread can acquire it on restore.
          eglMakeCurrent(self->egl_display, EGL_NO_SURFACE, EGL_NO_SURFACE,
                         EGL_NO_CONTEXT);
        }
      }
    }
  } else if (self->texture_sw != NULL && self->render_context != NULL) {
    g_mutex_lock(&self->mutex);
    if (!video_output_get_visibility(self)) {
      int skip = 1;
      mpv_render_param params[] = {
          {MPV_RENDER_PARAM_SKIP_RENDERING, &skip},
          {MPV_RENDER_PARAM_INVALID, NULL},
      };
      mpv_render_context_render(self->render_context, params);
    } else {
      const gint64 width = video_output_get_width(self);
      const gint64 height = video_output_get_height(self);
      if (width > 0 && height > 0) {
        gint32 size[] = {(gint32)width, (gint32)height};
        gint32 pitch = 4 * (gint32)width;
        mpv_render_param params[] = {
            {MPV_RENDER_PARAM_SW_SIZE, size},
            {MPV_RENDER_PARAM_SW_FORMAT, (void*)"rgb0"},
            {MPV_RENDER_PARAM_SW_STRIDE, &pitch},
            {MPV_RENDER_PARAM_SW_POINTER, self->pixel_buffer},
            {MPV_RENDER_PARAM_INVALID, NULL},
        };
        mpv_render_context_render(self->render_context, params);
        fl_texture_registrar_mark_texture_frame_available(
            self->texture_registrar, FL_TEXTURE(self->texture_sw));
      }
    }
    g_mutex_unlock(&self->mutex);
  }
  video_output_unlock_render(self);
  return G_SOURCE_REMOVE;
}

static void video_output_schedule_render(VideoOutput* self) {
  g_mutex_lock(&self->render_source_mutex);
  if (video_output_is_destroyed(self) || self->render_source_id != 0) {
    g_mutex_unlock(&self->render_source_mutex);
    return;
  }
  // Keep the source mutex held until its ID is stored. If the main context
  // dispatches the source immediately, its callback waits before clearing ID.
  self->render_source_id = g_idle_add_full(
      G_PRIORITY_DEFAULT, video_output_render_idle, g_object_ref(self),
      g_object_unref);
  g_mutex_unlock(&self->render_source_mutex);
}

VideoOutput* video_output_new(FlTextureRegistrar* texture_registrar,
                              FlView* view,
                              gint64 handle,
                              VideoOutputConfiguration configuration,
                              GError** error) {
  VideoOutput* self = VIDEO_OUTPUT(g_object_new(video_output_get_type(), NULL));
  self->texture_registrar = texture_registrar;
  self->handle = (mpv_handle*)handle;
  self->width = configuration.width;
  self->height = configuration.height;
  self->configuration = configuration;
#ifndef MPV_RENDER_API_TYPE_SW
  // MPV_RENDER_API_TYPE_SW must be available for S/W rendering.
  if (!self->configuration.enable_hardware_acceleration) {
    g_printerr("media_kit: VideoOutput: S/W rendering is not supported.\n");
  }
  self->configuration.enable_hardware_acceleration = TRUE;
#endif
  mpv_set_option_string(self->handle, "video-sync", "audio");
  // Causes frame drops with `pulse` audio output. (SlotSun/dart_simple_live#42)
  // mpv_set_option_string(self->handle, "video-timing-offset", "0");
  gboolean hardware_acceleration_supported = FALSE;
  if (self->configuration.enable_hardware_acceleration) {
    // Get Flutter's current EGL display (DO NOT share context)
    EGLDisplay flutter_display = eglGetCurrentDisplay();
    EGLContext flutter_context = eglGetCurrentContext();
    EGLSurface flutter_draw_surface = eglGetCurrentSurface(EGL_DRAW);
    EGLSurface flutter_read_surface = eglGetCurrentSurface(EGL_READ);

    self->flutter_egl_display = flutter_display;
    self->flutter_egl_context = flutter_context;
    self->flutter_egl_draw_surface = flutter_draw_surface;
    self->flutter_egl_read_surface = flutter_read_surface;
    
    if (flutter_display != EGL_NO_DISPLAY && flutter_context != EGL_NO_CONTEXT) {
      self->egl_display = flutter_display;
      
      // Bind OpenGL ES API (Flutter uses OpenGL ES on Linux)
      eglBindAPI(EGL_OPENGL_ES_API);
      
      // Query Flutter's EGL config and reuse it for compatibility
      EGLConfig config = NULL;
      EGLint config_id = 0;
      
      if (eglQueryContext(self->egl_display, flutter_context, EGL_CONFIG_ID, &config_id)) {
        g_print("media_kit: VideoOutput: Flutter's EGL config ID: %d\n", config_id);
        
        // Get Flutter's exact config
        EGLint num_configs = 0;
        EGLint config_attribs[] = { EGL_CONFIG_ID, config_id, EGL_NONE };
        
        if (eglChooseConfig(self->egl_display, config_attribs, &config, 1, &num_configs) && num_configs > 0) {
          g_print("media_kit: VideoOutput: Using Flutter's EGL config.\n");
        } else {
          g_printerr("media_kit: VideoOutput: Failed to get Flutter's EGL config by ID.\n");
          config = NULL;
        }
      } else {
        g_printerr("media_kit: VideoOutput: Failed to query Flutter's EGL config ID.\n");
      }
      
      if (config != NULL) {        
        // Create an isolated EGL context (NOT shared with Flutter)
        // This prevents OpenGL state pollution and resource contention
        EGLint context_attribs[] = {
            EGL_CONTEXT_CLIENT_VERSION, 2,
            EGL_NONE,
        };
        
        self->egl_context = eglCreateContext(self->egl_display, config, 
                                             EGL_NO_CONTEXT, context_attribs);
        
        if (self->egl_context != EGL_NO_CONTEXT) {
          // Make our isolated context current for initialization (surfaceless)
          if (eglMakeCurrent(self->egl_display, EGL_NO_SURFACE, EGL_NO_SURFACE, self->egl_context)) {
            // Create texture with our isolated context
            self->texture_gl = texture_gl_new(self);
            
            if (fl_texture_registrar_register_texture(
                    texture_registrar, FL_TEXTURE(self->texture_gl))) {
              self->texture_gl_registered = TRUE;
              // Initialize mpv with our isolated EGL context
              mpv_opengl_init_params gl_init_params{
                  [](auto, auto name) {
                    return (void*)eglGetProcAddress(name);
                  },
                  NULL,
              };
              
              mpv_render_param params[] = {
                  {MPV_RENDER_PARAM_API_TYPE, (void*)MPV_RENDER_API_TYPE_OPENGL},
                  {MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, (void*)&gl_init_params},
                  {MPV_RENDER_PARAM_INVALID, (void*)0},
                  {MPV_RENDER_PARAM_INVALID, (void*)0},
              };
              
              // VAAPI acceleration requires passing X11/Wayland display
              GdkDisplay* display = gdk_display_get_default();
              if (GDK_IS_WAYLAND_DISPLAY(display)) {
                params[2].type = MPV_RENDER_PARAM_WL_DISPLAY;
                params[2].data = gdk_wayland_display_get_wl_display(display);
              } else if (GDK_IS_X11_DISPLAY(display)) {
                params[2].type = MPV_RENDER_PARAM_X11_DISPLAY;
                params[2].data = gdk_x11_display_get_xdisplay(display);
              }
              
              if (mpv_render_context_create(&self->render_context, self->handle, params) == 0) {
                mpv_render_context_set_update_callback(
                    self->render_context,
                    [](void* data) {
                      video_output_schedule_render(VIDEO_OUTPUT(data));
                    },
                    self);
                hardware_acceleration_supported = TRUE;
                g_print("media_kit: VideoOutput: H/W rendering with isolated EGL context.\n");
              } else {
                g_printerr("media_kit: VideoOutput: Failed to create mpv_render_context.\n");
              }
            } else {
              g_printerr("media_kit: VideoOutput: Failed to register texture.\n");
            }
            
            // Restore Flutter's context
            if (!eglMakeCurrent(flutter_display, flutter_draw_surface,
                                flutter_read_surface, flutter_context)) {
              g_warning("media_kit: Could not restore Flutter's EGL context after video-output initialization (EGL error 0x%x).",
                        eglGetError());
              if (!eglMakeCurrent(flutter_display, EGL_NO_SURFACE,
                                  EGL_NO_SURFACE, EGL_NO_CONTEXT)) {
                g_warning("media_kit: Could not unbind the isolated EGL context after initialization (EGL error 0x%x).",
                          eglGetError());
              }
            }
          } else {
            g_printerr("media_kit: VideoOutput: Failed to make isolated EGL context current. Error: 0x%x\n", eglGetError());
          }
        } else {
          g_printerr("media_kit: VideoOutput: Failed to create isolated EGL context. Error: 0x%x\n", eglGetError());
        }
      } else {
        g_printerr("media_kit: VideoOutput: Could not obtain Flutter's EGL config.\n");
      }
    } else {
      g_printerr("media_kit: VideoOutput: EGL display or context is invalid.\n");
    }
  }
#ifdef MPV_RENDER_API_TYPE_SW
  if (!hardware_acceleration_supported) {
    g_printerr("media_kit: VideoOutput: S/W rendering.\n");
    // H/W rendering failed. Fallback to S/W rendering.
    if (self->texture_gl != NULL) {
      if (self->texture_gl_registered) {
        fl_texture_registrar_unregister_texture(
            texture_registrar, FL_TEXTURE(self->texture_gl));
        self->texture_gl_registered = FALSE;
      }
      g_clear_object(&self->texture_gl);
    }
    if (!release_egl_context(self, "before software fallback")) {
      g_printerr("media_kit: VideoOutput: Cannot safely switch away from the failed EGL context; skipping S/W rendering.\n");
      g_set_error_literal(
          error, video_output_error_quark(), 1,
          "Could not release the failed EGL context, so no video texture "
          "could be created safely.");
      g_object_unref(self);
      return NULL;
    }
    self->pixel_buffer = g_new0(guint8, SW_RENDERING_PIXEL_BUFFER_SIZE);
    self->texture_sw = texture_sw_new(self);
    if (fl_texture_registrar_register_texture(texture_registrar,
                                              FL_TEXTURE(self->texture_sw))) {
      self->texture_sw_registered = TRUE;
      mpv_render_param params[] = {
          {MPV_RENDER_PARAM_API_TYPE, (void*)MPV_RENDER_API_TYPE_SW},
          {MPV_RENDER_PARAM_INVALID, (void*)0},
      };
      if (mpv_render_context_create(&self->render_context, self->handle,
                                    params) == 0) {
        mpv_render_context_set_update_callback(
                    self->render_context,
                    [](void* data) {
                      video_output_schedule_render(VIDEO_OUTPUT(data));
                    },
                    self);
      }
    }
  }
#endif
  const gboolean has_registered_texture =
      (self->texture_gl != NULL && self->texture_gl_registered) ||
      (self->texture_sw != NULL && self->texture_sw_registered);
  if (!has_registered_texture || self->render_context == NULL) {
    g_set_error_literal(
        error, video_output_error_quark(), 2,
        "Could not initialize a usable Linux video texture. Check EGL/GPU "
        "initialization and software-rendering support.");
    g_object_unref(self);
    return NULL;
  }
  return self;
}

void video_output_set_texture_update_callback(
    VideoOutput* self,
    TextureUpdateCallback texture_update_callback,
    gpointer texture_update_callback_context,
    GDestroyNotify texture_update_callback_context_destroy_notify) {
  self->texture_update_callback = texture_update_callback;
  self->texture_update_callback_context = texture_update_callback_context;
  self->texture_update_callback_context_destroy_notify =
      texture_update_callback_context_destroy_notify;
  // Notify initial dimensions as (1, 1) if |width| & |height| are 0 i.e.
  // texture & video frame size is based on playing file's resolution. This
  // will make sure that `Texture` widget on Flutter's widget tree is actually
  // mounted & |fl_texture_registrar_mark_texture_frame_available| actually
  // invokes the |TextureGL| or |TextureSW| callbacks. Otherwise it will be a
  // never ending deadlock where no video frames are ever rendered.
  gint64 texture_id = video_output_get_texture_id(self);
  if (self->width == 0 || self->height == 0) {
    self->texture_update_callback(texture_id, 1, 1,
                                  self->texture_update_callback_context);
  } else {
    self->texture_update_callback(texture_id, self->width, self->height,
                                  self->texture_update_callback_context);
  }
}

void video_output_set_size(VideoOutput* self, gint64 width, gint64 height) {
  video_output_lock_render(self);
  // H/W
  if (self->texture_gl) {
    self->width = width;
    self->height = height;
  }
  // S/W
  if (self->texture_sw) {
    self->width = CLAMP(width, 0, SW_RENDERING_MAX_WIDTH);
    self->height = CLAMP(height, 0, SW_RENDERING_MAX_HEIGHT);
  }
  video_output_unlock_render(self);
  video_output_schedule_render(self);
}

mpv_render_context* video_output_get_render_context(VideoOutput* self) {
  return self->render_context;
}

EGLDisplay video_output_get_egl_display(VideoOutput* self) {
  return self->egl_display;
}

EGLContext video_output_get_egl_context(VideoOutput* self) {
  return self->egl_context;
}

EGLSurface video_output_get_egl_surface(VideoOutput* self) {
  return self->egl_surface;
}

EGLDisplay video_output_get_flutter_egl_display(VideoOutput* self) {
  return self->flutter_egl_display;
}

EGLContext video_output_get_flutter_egl_context(VideoOutput* self) {
  return self->flutter_egl_context;
}

EGLSurface video_output_get_flutter_egl_draw_surface(VideoOutput* self) {
  return self->flutter_egl_draw_surface;
}

EGLSurface video_output_get_flutter_egl_read_surface(VideoOutput* self) {
  return self->flutter_egl_read_surface;
}

guint8* video_output_get_pixel_buffer(VideoOutput* self) {
  return self->pixel_buffer;
}

gint64 video_output_get_width(VideoOutput* self) {
  // Fixed width.
  if (self->width) {
    return self->width;
  }

  // Video resolution dependent width.
  gint64 width = 0;
  gint64 height = 0;

  mpv_node params{};
  const int status = mpv_get_property(self->handle, "video-out-params",
                                      MPV_FORMAT_NODE, &params);

  int64_t dw = 0, dh = 0, rotate = 0;
  if (status >= 0 && params.format == MPV_FORMAT_NODE_MAP) {
    for (int32_t i = 0; i < params.u.list->num; i++) {
      char* key = params.u.list->keys[i];
      auto value = params.u.list->values[i];
      if (value.format == MPV_FORMAT_INT64) {
        if (strcmp(key, "dw") == 0) {
          dw = value.u.int64;
        }
        if (strcmp(key, "dh") == 0) {
          dh = value.u.int64;
        }
        if (strcmp(key, "rotate") == 0) {
          rotate = value.u.int64;
        }
      }
    }
  }
  if (status >= 0) mpv_free_node_contents(&params);

  width = rotate == 0 || rotate == 180 ? dw : dh;
  height = rotate == 0 || rotate == 180 ? dh : dw;

  if (self->texture_sw != NULL) {
    return fit_software_dimensions(width, height).first;
  }

  return width;
}

gint64 video_output_get_height(VideoOutput* self) {
  // Fixed height.
  if (self->height) {
    return self->height;
  }

  // Video resolution dependent height.
  gint64 width = 0;
  gint64 height = 0;

  mpv_node params{};
  const int status = mpv_get_property(self->handle, "video-out-params",
                                      MPV_FORMAT_NODE, &params);

  int64_t dw = 0, dh = 0, rotate = 0;
  if (status >= 0 && params.format == MPV_FORMAT_NODE_MAP) {
    for (int32_t i = 0; i < params.u.list->num; i++) {
      char* key = params.u.list->keys[i];
      auto value = params.u.list->values[i];
      if (value.format == MPV_FORMAT_INT64) {
        if (strcmp(key, "dw") == 0) {
          dw = value.u.int64;
        }
        if (strcmp(key, "dh") == 0) {
          dh = value.u.int64;
        }
        if (strcmp(key, "rotate") == 0) {
          rotate = value.u.int64;
        }
      }
    }
  }
  if (status >= 0) mpv_free_node_contents(&params);

  width = rotate == 0 || rotate == 180 ? dw : dh;
  height = rotate == 0 || rotate == 180 ? dh : dw;

  if (self->texture_sw != NULL) {
    return fit_software_dimensions(width, height).second;
  }

  return height;
}

gint64 video_output_get_texture_id(VideoOutput* self) {
  // H/W
  if (self->texture_gl) {
    return (gint64)self->texture_gl;
  }
  // S/W
  if (self->texture_sw) {
    return (gint64)self->texture_sw;
  }
  g_assert_not_reached();
  return -1;
}

void video_output_notify_texture_update(VideoOutput* self) {
  gint64 id = video_output_get_texture_id(self);
  gint64 width = video_output_get_width(self);
  gint64 height = video_output_get_height(self);
  gpointer context = self->texture_update_callback_context;
  if (self->texture_update_callback != NULL) {
    self->texture_update_callback(id, width, height, context);
  }
}

void video_output_set_visibility(VideoOutput* self, gboolean visible) {
  g_atomic_int_set(&self->visible, visible ? 1 : 0);
  if (visible) video_output_schedule_render(self);
}

gboolean video_output_get_visibility(VideoOutput* self) {
  return g_atomic_int_get(&self->visible) != 0;
}

