// This file is a part of media_kit
// (https://github.com/media-kit/media-kit).
//
// Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
// All rights reserved.
// Use of this source code is governed by MIT license that can be found in the
// LICENSE file.

#include "include/media_kit_video/texture_gl.h"

#include <epoxy/gl.h>
#include <epoxy/egl.h>

typedef EGLImageKHR (*CreateEglImageProc)(EGLDisplay,
                                          EGLContext,
                                          EGLenum,
                                          EGLClientBuffer,
                                          const EGLint*);
typedef EGLBoolean (*DestroyEglImageProc)(EGLDisplay, EGLImageKHR);
typedef void (*ImageTargetTextureProc)(GLenum, GLeglImageOES);

static CreateEglImageProc create_egl_image = nullptr;
static DestroyEglImageProc destroy_egl_image = nullptr;
static ImageTargetTextureProc image_target_texture = nullptr;
static gsize egl_image_extensions_state = 0;

static gboolean init_egl_image_extensions() {
  if (g_once_init_enter(&egl_image_extensions_state)) {
    create_egl_image = reinterpret_cast<CreateEglImageProc>(
        eglGetProcAddress("eglCreateImageKHR"));
    destroy_egl_image = reinterpret_cast<DestroyEglImageProc>(
        eglGetProcAddress("eglDestroyImageKHR"));
    image_target_texture = reinterpret_cast<ImageTargetTextureProc>(
        eglGetProcAddress("glEGLImageTargetTexture2DOES"));
    const gsize ready = create_egl_image != nullptr &&
                                destroy_egl_image != nullptr &&
                                image_target_texture != nullptr
                            ? 1
                            : 2;
    g_once_init_leave(&egl_image_extensions_state, ready);
  }
  return egl_image_extensions_state == 1;
}

static GQuark texture_gl_error_quark() {
  return g_quark_from_static_string("media-kit-video-texture-gl-error");
}

static gboolean set_texture_error(GError** error,
                                 gint code,
                                 const gchar* message) {
  if (error != nullptr && *error == nullptr) {
    g_set_error_literal(error, texture_gl_error_quark(), code, message);
  }
  return FALSE;
}

static gboolean set_egl_error(GError** error, const gchar* operation) {
  const EGLint code = eglGetError();
  if (error != nullptr && *error == nullptr) {
    g_set_error(error, texture_gl_error_quark(), code,
                "%s failed (EGL error 0x%x)", operation, code);
  }
  return FALSE;
}

struct EglContextState {
  EGLDisplay display;
  EGLContext context;
  EGLSurface draw_surface;
  EGLSurface read_surface;
};

static EglContextState capture_egl_context() {
  return {eglGetCurrentDisplay(), eglGetCurrentContext(),
          eglGetCurrentSurface(EGL_DRAW), eglGetCurrentSurface(EGL_READ)};
}

static gboolean restore_egl_context(const EglContextState& state,
                                    EGLDisplay fallback_display,
                                    GError** error) {
  const EGLDisplay display = state.display != EGL_NO_DISPLAY
                                 ? state.display
                                 : fallback_display;
  if (display == EGL_NO_DISPLAY) {
    return set_texture_error(error, 1,
                             "Cannot restore EGL state without a display.");
  }
  const gboolean restored = state.context == EGL_NO_CONTEXT
                                ? eglMakeCurrent(display, EGL_NO_SURFACE,
                                                EGL_NO_SURFACE, EGL_NO_CONTEXT)
                                : eglMakeCurrent(display, state.draw_surface,
                                                state.read_surface,
                                                state.context);
  if (!restored) return set_egl_error(error, "eglMakeCurrent (restore)");
  return TRUE;
}

// Failure to restore Flutter's context must not strand mpv's context on the
// raster thread. Let the caller's next frame callback bind Flutter's context
// again by explicitly unbinding whichever display was used for mpv rendering.
static void restore_or_unbind_egl_context(const EglContextState& state,
                                          EGLDisplay fallback_display) {
  if (restore_egl_context(state, fallback_display, nullptr)) return;

  g_warning("media_kit: Could not restore the previous EGL context; attempting to unbind the current context.");
  const EGLDisplay display = fallback_display != EGL_NO_DISPLAY
                                 ? fallback_display
                                 : state.display;
  if (display != EGL_NO_DISPLAY &&
      !eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE,
                      EGL_NO_CONTEXT)) {
    g_warning("media_kit: Could not unbind the EGL context after a failed restore (EGL error 0x%x).",
              eglGetError());
  }
}

static gboolean make_mpv_context_current(VideoOutput* video_output,
                                         GError** error) {
  const EGLDisplay display = video_output_get_egl_display(video_output);
  const EGLContext context = video_output_get_egl_context(video_output);
  if (display == EGL_NO_DISPLAY || context == EGL_NO_CONTEXT) {
    return set_texture_error(error, 2,
                             "The mpv EGL context is unavailable.");
  }
  if (!eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, context)) {
    return set_egl_error(error, "eglMakeCurrent (mpv)");
  }
  return TRUE;
}

static void clear_gl_errors() {
  while (glGetError() != GL_NO_ERROR) {
  }
}

static gboolean check_gl_error(GError** error, const gchar* operation) {
  const GLenum code = glGetError();
  if (code == GL_NO_ERROR) return TRUE;
  while (glGetError() != GL_NO_ERROR) {
  }
  if (error != nullptr && *error == nullptr) {
    g_set_error(error, texture_gl_error_quark(), code,
                "%s failed (OpenGL error 0x%x)", operation, code);
  }
  return FALSE;
}

class VideoOutputRenderLock {
 public:
  explicit VideoOutputRenderLock(VideoOutput* video_output)
      : video_output_(video_output) {
    video_output_lock_render(video_output_);
  }
  ~VideoOutputRenderLock() { video_output_unlock_render(video_output_); }

  VideoOutputRenderLock(const VideoOutputRenderLock&) = delete;
  VideoOutputRenderLock& operator=(const VideoOutputRenderLock&) = delete;

 private:
  VideoOutput* video_output_;
};

struct _TextureGL {
  FlTextureGL parent_instance;
  guint32 name;              // Flutter's texture name
  guint32 fbo;               // mpv's FBO
  guint32 mpv_texture;       // mpv's texture
  EGLImageKHR egl_image;     // EGLImage for sharing between contexts
  guint32 current_width;
  guint32 current_height;
  VideoOutput* video_output;
};

G_DEFINE_TYPE(TextureGL, texture_gl, fl_texture_gl_get_type())

static void texture_gl_init(TextureGL* self) {
  self->name = 0;
  self->fbo = 0;
  self->mpv_texture = 0;
  self->egl_image = EGL_NO_IMAGE_KHR;
  self->current_width = 1;
  self->current_height = 1;
  self->video_output = NULL;
}

static void texture_gl_dispose(GObject* object) {
  TextureGL* self = TEXTURE_GL(object);
  VideoOutput* video_output = self->video_output;
  if (video_output != nullptr) video_output_lock_render(video_output);

  const EglContextState current = capture_egl_context();
  const EGLDisplay flutter_display = video_output == nullptr
                                         ? EGL_NO_DISPLAY
                                         : video_output_get_flutter_egl_display(
                                               video_output);
  const EGLContext flutter_context = video_output == nullptr
                                         ? EGL_NO_CONTEXT
                                         : video_output_get_flutter_egl_context(
                                               video_output);
  const EGLSurface flutter_draw =
      video_output == nullptr
          ? EGL_NO_SURFACE
          : video_output_get_flutter_egl_draw_surface(video_output);
  const EGLSurface flutter_read =
      video_output == nullptr
          ? EGL_NO_SURFACE
          : video_output_get_flutter_egl_read_surface(video_output);

  // The Flutter texture name belongs to Flutter's context. Dispose can run on
  // a platform thread with no current GL context, so bind the captured context
  // only after unregistering has drained active texture callbacks. If EGL says
  // that context is still current on another thread, do not delete the name in
  // an unrelated context.
  if (self->name != 0) {
    gboolean flutter_context_current =
        current.context == flutter_context &&
        current.display == flutter_display && flutter_context != EGL_NO_CONTEXT;
    if (!flutter_context_current && flutter_display != EGL_NO_DISPLAY &&
        flutter_context != EGL_NO_CONTEXT) {
      flutter_context_current = eglMakeCurrent(
          flutter_display, flutter_draw, flutter_read, flutter_context);
    }
    if (flutter_context_current) {
      glDeleteTextures(1, &self->name);
      self->name = 0;
      if (current.context != flutter_context &&
          !restore_egl_context(current, flutter_display, nullptr)) {
        g_warning("media_kit: Could not restore EGL state after deleting the Flutter texture.");
        eglMakeCurrent(flutter_display, EGL_NO_SURFACE, EGL_NO_SURFACE,
                       EGL_NO_CONTEXT);
      }
    } else {
      g_warning("media_kit: Flutter EGL context is unavailable during texture disposal; the Flutter texture name will be reclaimed when that context is destroyed.");
      self->name = 0;
    }
  }

  const EGLDisplay egl_display = video_output == nullptr
                                    ? EGL_NO_DISPLAY
                                    : video_output_get_egl_display(video_output);
  if (self->egl_image != EGL_NO_IMAGE_KHR) {
    if (destroy_egl_image != nullptr && egl_display != EGL_NO_DISPLAY) {
      if (!destroy_egl_image(egl_display, self->egl_image)) {
        g_warning("media_kit: Could not destroy the EGLImage (EGL error 0x%x).",
                  eglGetError());
      }
    }
    self->egl_image = EGL_NO_IMAGE_KHR;
  }

  // Clean up mpv's GL resources only with the isolated context current.
  if (video_output != nullptr &&
      video_output_get_egl_context(video_output) != EGL_NO_CONTEXT) {
    if (eglMakeCurrent(egl_display, EGL_NO_SURFACE, EGL_NO_SURFACE,
                       video_output_get_egl_context(video_output))) {
      if (self->mpv_texture != 0) {
        glDeleteTextures(1, &self->mpv_texture);
        self->mpv_texture = 0;
      }
      if (self->fbo != 0) {
        glDeleteFramebuffers(1, &self->fbo);
        self->fbo = 0;
      }
      if (!restore_egl_context(current, egl_display, nullptr)) {
        g_warning("media_kit: Could not restore EGL state after deleting mpv textures.");
        eglMakeCurrent(egl_display, EGL_NO_SURFACE, EGL_NO_SURFACE,
                       EGL_NO_CONTEXT);
      }
    } else {
      g_warning("media_kit: Could not make the mpv EGL context current during texture disposal; context destruction will reclaim its GL resources.");
      self->mpv_texture = 0;
      self->fbo = 0;
    }
  }

  self->current_width = 1;
  self->current_height = 1;
  self->video_output = NULL;
  if (video_output != nullptr) video_output_unlock_render(video_output);
  G_OBJECT_CLASS(texture_gl_parent_class)->dispose(object);
}

static void texture_gl_class_init(TextureGLClass* klass) {
  FL_TEXTURE_GL_CLASS(klass)->populate = texture_gl_populate_texture;
  G_OBJECT_CLASS(klass)->dispose = texture_gl_dispose;
}

TextureGL* texture_gl_new(VideoOutput* video_output) {
  TextureGL* self = TEXTURE_GL(g_object_new(texture_gl_get_type(), NULL));
  self->video_output = video_output;
  return self;
}

gboolean texture_gl_populate_texture(FlTextureGL* texture,
                                     guint32* target,
                                     guint32* name,
                                     guint32* width,
                                     guint32* height,
                                     GError** error) {
  TextureGL* self = TEXTURE_GL(texture);
  VideoOutput* video_output = self->video_output;
  if (video_output == nullptr) {
    return set_texture_error(error, 3,
                             "The video output was released before texture population.");
  }
  VideoOutputRenderLock render_lock(video_output);
  if (video_output_is_destroyed(video_output)) {
    return set_texture_error(error, 4,
                             "The video output is shutting down.");
  }

  const EGLDisplay egl_display =
      video_output_get_egl_display(video_output);
  const EGLContext egl_context =
      video_output_get_egl_context(video_output);
  const EglContextState flutter = capture_egl_context();
  if (flutter.display == EGL_NO_DISPLAY ||
      flutter.context == EGL_NO_CONTEXT || egl_display != flutter.display) {
    return set_texture_error(
        error, 5,
        "Texture population requires Flutter's current EGL context on the mpv display.");
  }
  if (!init_egl_image_extensions()) {
    return set_texture_error(error, 6,
                             "Required EGLImage extension entry points are unavailable.");
  }

  const gint64 video_width = video_output_get_width(video_output);
  const gint64 video_height = video_output_get_height(video_output);
  if (video_width > G_MAXINT32 || video_height > G_MAXINT32) {
    return set_texture_error(error, 7,
                             "Video dimensions exceed the OpenGL texture limit.");
  }
  const gint32 required_width = static_cast<gint32>(video_width);
  const gint32 required_height = static_cast<gint32>(video_height);
  const gboolean visible = video_output_get_visibility(video_output);

  if (visible && required_width > 0 && required_height > 0) {
    mpv_render_context* render_context =
        video_output_get_render_context(video_output);
    if (render_context == nullptr || egl_context == EGL_NO_CONTEXT) {
      return set_texture_error(error, 8,
                               "The mpv render context is unavailable.");
    }

    const gboolean first_frame =
        self->name == 0 || self->fbo == 0 || self->mpv_texture == 0;
    const gboolean resize = self->current_width != required_width ||
                            self->current_height != required_height;
    if (first_frame || resize) {
      // The Flutter texture name must be deleted while Flutter's context is
      // current; EGLImage resources are deleted under mpv's isolated context.
      if (self->name != 0) {
        glDeleteTextures(1, &self->name);
        self->name = 0;
      }
      if (!make_mpv_context_current(video_output, error)) return FALSE;

      if (self->mpv_texture != 0) {
        glDeleteTextures(1, &self->mpv_texture);
        self->mpv_texture = 0;
      }
      if (self->fbo != 0) {
        glDeleteFramebuffers(1, &self->fbo);
        self->fbo = 0;
      }
      if (self->egl_image != EGL_NO_IMAGE_KHR) {
        if (!destroy_egl_image(egl_display, self->egl_image)) {
          const EGLint code = eglGetError();
          restore_or_unbind_egl_context(flutter, egl_display);
          if (error != nullptr && *error == nullptr) {
            g_set_error(error, texture_gl_error_quark(), code,
                        "eglDestroyImageKHR failed during resize (EGL error 0x%x)",
                        code);
          }
          return FALSE;
        }
        self->egl_image = EGL_NO_IMAGE_KHR;
      }

      clear_gl_errors();
      glGenFramebuffers(1, &self->fbo);
      glGenTextures(1, &self->mpv_texture);
      if (self->fbo == 0 || self->mpv_texture == 0) {
        if (self->mpv_texture != 0) glDeleteTextures(1, &self->mpv_texture);
        if (self->fbo != 0) glDeleteFramebuffers(1, &self->fbo);
        self->mpv_texture = 0;
        self->fbo = 0;
        restore_or_unbind_egl_context(flutter, egl_display);
        return set_texture_error(error, 9,
                                 "Could not allocate OpenGL framebuffer resources.");
      }

      glBindFramebuffer(GL_FRAMEBUFFER, self->fbo);
      glBindTexture(GL_TEXTURE_2D, self->mpv_texture);
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
      glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, required_width, required_height,
                   0, GL_RGBA, GL_UNSIGNED_BYTE, nullptr);
      glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
                             GL_TEXTURE_2D, self->mpv_texture, 0);
      const GLenum framebuffer_status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
      glBindFramebuffer(GL_FRAMEBUFFER, 0);
      glBindTexture(GL_TEXTURE_2D, 0);
      if (framebuffer_status != GL_FRAMEBUFFER_COMPLETE ||
          !check_gl_error(error, "OpenGL framebuffer allocation")) {
        glDeleteTextures(1, &self->mpv_texture);
        glDeleteFramebuffers(1, &self->fbo);
        self->mpv_texture = 0;
        self->fbo = 0;
        restore_or_unbind_egl_context(flutter, egl_display);
        if (framebuffer_status != GL_FRAMEBUFFER_COMPLETE) {
          return set_texture_error(error, 10,
                                   "The OpenGL framebuffer is incomplete.");
        }
        return FALSE;
      }

      const EGLint image_attributes[] = {EGL_NONE};
      self->egl_image = create_egl_image(
          egl_display, egl_context, EGL_GL_TEXTURE_2D_KHR,
          reinterpret_cast<EGLClientBuffer>(
              static_cast<guintptr>(self->mpv_texture)),
          image_attributes);
      if (self->egl_image == EGL_NO_IMAGE_KHR) {
        const EGLint code = eglGetError();
        glDeleteTextures(1, &self->mpv_texture);
        glDeleteFramebuffers(1, &self->fbo);
        self->mpv_texture = 0;
        self->fbo = 0;
        restore_or_unbind_egl_context(flutter, egl_display);
        if (error != nullptr && *error == nullptr) {
          g_set_error(error, texture_gl_error_quark(), code,
                      "eglCreateImageKHR failed (EGL error 0x%x)", code);
        }
        return FALSE;
      }
      glFlush();
      if (!check_gl_error(error, "OpenGL texture flush")) {
        if (destroy_egl_image(egl_display, self->egl_image)) {
          self->egl_image = EGL_NO_IMAGE_KHR;
        } else {
          g_warning("media_kit: Could not destroy the EGLImage after a texture allocation failure (EGL error 0x%x).",
                    eglGetError());
        }
        glDeleteTextures(1, &self->mpv_texture);
        glDeleteFramebuffers(1, &self->fbo);
        self->mpv_texture = 0;
        self->fbo = 0;
        restore_or_unbind_egl_context(flutter, egl_display);
        return FALSE;
      }
      if (!restore_egl_context(flutter, egl_display, error)) {
        // The mpv context is still expected to be current after a failed
        // restore. Reclaim partial state there, then leave it unbound if
        // Flutter's previous context cannot be restored.
        if (eglGetCurrentContext() == egl_context) {
          if (destroy_egl_image(egl_display, self->egl_image)) {
            self->egl_image = EGL_NO_IMAGE_KHR;
          } else {
            g_warning("media_kit: Could not destroy the EGLImage after a context-restore failure (EGL error 0x%x).",
                      eglGetError());
          }
          glDeleteTextures(1, &self->mpv_texture);
          glDeleteFramebuffers(1, &self->fbo);
          self->mpv_texture = 0;
          self->fbo = 0;
        }
        restore_or_unbind_egl_context(flutter, egl_display);
        return FALSE;
      }

      clear_gl_errors();
      glGenTextures(1, &self->name);
      if (self->name != 0) {
        glBindTexture(GL_TEXTURE_2D, self->name);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        image_target_texture(GL_TEXTURE_2D, self->egl_image);
        glBindTexture(GL_TEXTURE_2D, 0);
      }
      if (self->name == 0 ||
          !check_gl_error(error, "Creating Flutter's EGLImage texture")) {
        if (self->name != 0) glDeleteTextures(1, &self->name);
        self->name = 0;
        if (make_mpv_context_current(video_output, nullptr)) {
          if (destroy_egl_image(egl_display, self->egl_image)) {
            self->egl_image = EGL_NO_IMAGE_KHR;
          } else {
            g_warning("media_kit: Could not destroy the EGLImage after Flutter texture attachment failed (EGL error 0x%x).",
                      eglGetError());
          }
          glDeleteTextures(1, &self->mpv_texture);
          glDeleteFramebuffers(1, &self->fbo);
          self->mpv_texture = 0;
          self->fbo = 0;
          restore_or_unbind_egl_context(flutter, egl_display);
        }
        if (error != nullptr && *error == nullptr) {
          set_texture_error(error, 11,
                            "Could not attach the EGLImage to Flutter's texture.");
        }
        return FALSE;
      }

      self->current_width = required_width;
      self->current_height = required_height;
      video_output_notify_texture_update(video_output);
    }

    if (self->fbo == 0 || self->name == 0 ||
        self->egl_image == EGL_NO_IMAGE_KHR) {
      return set_texture_error(error, 12,
                               "OpenGL texture resources are incomplete.");
    }

    if (!make_mpv_context_current(video_output, error)) return FALSE;
    clear_gl_errors();
    glBindFramebuffer(GL_FRAMEBUFFER, self->fbo);
    mpv_opengl_fbo fbo{static_cast<gint32>(self->fbo), required_width,
                       required_height, 0};
    int flip_y = 0;
    mpv_render_param params[] = {
        {MPV_RENDER_PARAM_OPENGL_FBO, &fbo},
        {MPV_RENDER_PARAM_FLIP_Y, &flip_y},
        {MPV_RENDER_PARAM_INVALID, nullptr},
    };
    mpv_render_context_render(render_context, params);
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    glFlush();
    const gboolean rendered = check_gl_error(error, "mpv OpenGL rendering");
    const gboolean restored =
        restore_egl_context(flutter, egl_display, error);
    if (!rendered || !restored) {
      if (!restored) restore_or_unbind_egl_context(flutter, egl_display);
      return FALSE;
    }
  }

  if (self->name == 0) {
    // A dummy texture lets Flutter keep the texture mounted before the first
    // video frame. The callback is only entered with Flutter's context current.
    clear_gl_errors();
    glGenTextures(1, &self->name);
    if (self->name == 0) {
      return set_texture_error(error, 13,
                               "Could not allocate Flutter's placeholder texture.");
    }
    glBindTexture(GL_TEXTURE_2D, self->name);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, 1, 1, 0, GL_RGBA,
                 GL_UNSIGNED_BYTE, nullptr);
    glBindTexture(GL_TEXTURE_2D, 0);
    if (!check_gl_error(error, "Creating Flutter's placeholder texture")) {
      glDeleteTextures(1, &self->name);
      self->name = 0;
      return FALSE;
    }
    self->current_width = 1;
    self->current_height = 1;
  }

  *target = GL_TEXTURE_2D;
  *name = self->name;
  *width = self->current_width;
  *height = self->current_height;
  return TRUE;
}
