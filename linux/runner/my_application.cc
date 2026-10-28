#include "my_application.h"

#include <flutter_linux/flutter_linux.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include "flutter/generated_plugin_registrant.h"
#include "mpris_player.h"

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
  GtkWindow* window;
  FlView* view;
  FlMethodChannel* single_instance_channel;
  GPtrArray* pending_open_files;
  MprisPlayer* mpris_player;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

// Forward paths to the running Flutter instance via MethodChannel mpvson/single_instance
static void forward_paths_to_flutter(MyApplication* self, GPtrArray* paths) {
  if (paths == nullptr || paths->len == 0) {
    return;
  }

  if (self->single_instance_channel == nullptr) {
    for (guint i = 0; i < paths->len; i++) {
      const gchar* p = (const gchar*)g_ptr_array_index(paths, i);
      g_ptr_array_add(self->pending_open_files, g_strdup(p));
    }
    return;
  }

  FlValue* args = fl_value_new_list();
  for (guint i = 0; i < paths->len; i++) {
    const gchar* p = (const gchar*)g_ptr_array_index(paths, i);
    fl_value_append_take(args, fl_value_new_string(p));
  }

  fl_method_channel_invoke_method(self->single_instance_channel,
                                  "open",
                                  args,
                                  nullptr,
                                  nullptr,
                                  nullptr);
}

// Called when first Flutter frame received.
static void first_frame_cb(MyApplication* self, FlView* view) {
  gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);

  if (self->window != nullptr) {
    gtk_window_present(self->window);
    return;
  }

  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));
  self->window = window;

  // Use a header bar when running in GNOME as this is the common style used
  // by applications and is the setup most users will be using (e.g. Ubuntu
  // desktop).
  // If running on X and not using GNOME then just use a traditional title bar
  // in case the window manager does more exotic layout, e.g. tiling.
  // If running on Wayland assume the header bar will work (may need changing
  // if future cases occur).
  gboolean use_header_bar = TRUE;
#ifdef GDK_WINDOWING_X11
  GdkScreen* screen = gtk_window_get_screen(window);
  if (GDK_IS_X11_SCREEN(screen)) {
    const gchar* wm_name = gdk_x11_screen_get_window_manager_name(screen);
    if (g_strcmp0(wm_name, "GNOME Shell") != 0) {
      use_header_bar = FALSE;
    }
  }
#endif
  if (use_header_bar) {
    GtkHeaderBar* header_bar = GTK_HEADER_BAR(gtk_header_bar_new());
    gtk_widget_show(GTK_WIDGET(header_bar));
    gtk_header_bar_set_title(header_bar, "Mpvson");
    gtk_header_bar_set_show_close_button(header_bar, TRUE);
    gtk_window_set_titlebar(window, GTK_WIDGET(header_bar));
  } else {
    gtk_window_set_title(window, "Mpvson");
  }

  gtk_window_set_default_size(window, 1240, 780);

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(
      project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  self->view = view;

  GdkRGBA background_color;
  gdk_rgba_parse(&background_color, "#0B1220");
  fl_view_set_background_color(view, &background_color);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  // Show the window when Flutter renders.
  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(first_frame_cb),
                           self);
  gtk_widget_realize(GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));

  // Initialize MethodChannel mpvson/single_instance
  g_autoptr(FlPluginRegistrar) registrar =
      fl_plugin_registry_get_registrar_for_plugin(FL_PLUGIN_REGISTRY(view),
                                                  "MpvsonRunner");
  FlBinaryMessenger* messenger = fl_plugin_registrar_get_messenger(registrar);

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  self->single_instance_channel = fl_method_channel_new(
      messenger, "mpvson/single_instance", FL_METHOD_CODEC(codec));

  fl_method_channel_set_method_call_handler(
      self->single_instance_channel,
      [](FlMethodChannel* channel, FlMethodCall* method_call, gpointer user_data) {
        fl_method_call_respond_success(method_call, nullptr, nullptr);
      },
      self,
      nullptr);

  // Flush any open requests queued prior to channel readiness
  if (self->pending_open_files != nullptr && self->pending_open_files->len > 0) {
    FlValue* args = fl_value_new_list();
    for (guint i = 0; i < self->pending_open_files->len; i++) {
      const gchar* p = (const gchar*)g_ptr_array_index(self->pending_open_files, i);
      fl_value_append_take(args, fl_value_new_string(p));
    }
    fl_method_channel_invoke_method(self->single_instance_channel,
                                    "open",
                                    args,
                                    nullptr,
                                    nullptr,
                                    nullptr);
    g_ptr_array_set_size(self->pending_open_files, 0);
  }

  // Initialize and start MPRIS player & power management bridge
  self->mpris_player = mpris_player_new(application, window, messenger);
  mpris_player_start(self->mpris_player);

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::open.
static void my_application_open(GApplication* application,
                                GFile** files,
                                gint n_files,
                                const gchar* hint) {
  MyApplication* self = MY_APPLICATION(application);

  if (self->window == nullptr) {
    g_application_activate(application);
  } else {
    gtk_window_present(self->window);
  }

  GPtrArray* paths = g_ptr_array_new_with_free_func(g_free);
  for (gint i = 0; i < n_files; i++) {
    gchar* path = g_file_get_path(files[i]);
    if (path == nullptr) {
      path = g_file_get_uri(files[i]);
    }
    if (path != nullptr) {
      g_ptr_array_add(paths, path);
    }
  }

  forward_paths_to_flutter(self, paths);
  g_ptr_array_unref(paths);
}

// Implements GApplication::command_line.
static int my_application_command_line(GApplication* application,
                                       GApplicationCommandLine* cmdline) {
  MyApplication* self = MY_APPLICATION(application);

  gint argc = 0;
  gchar** argv = g_application_command_line_get_arguments(cmdline, &argc);

  gboolean is_primary_boot = (self->window == nullptr);

  if (is_primary_boot) {
    g_application_activate(application);
  } else {
    gtk_window_present(self->window);
  }

  GPtrArray* paths = g_ptr_array_new_with_free_func(g_free);
  gboolean enqueue = g_variant_dict_contains(
      g_application_command_line_get_options_dict(cmdline), "enqueue");
  for (gint i = 1; i < argc; i++) {
    if (g_strcmp0(argv[i], "--enqueue") == 0) {
      enqueue = TRUE;
      continue;
    }
    if (argv[i][0] == '-') {
      continue;
    }
    g_autoptr(GFile) file =
        g_application_command_line_create_file_for_arg(cmdline, argv[i]);
    gchar* path = g_file_get_path(file);
    if (path == nullptr) {
      path = g_file_get_uri(file);
    }
    if (path == nullptr) {
      path = g_strdup(argv[i]);
    }
    g_ptr_array_add(paths, path);
  }

  // When a secondary instance is invoked or new paths arrive while running,
  // notify Flutter via MethodChannel mpvson/single_instance.
  if (!is_primary_boot && paths->len > 0) {
    if (enqueue) g_ptr_array_add(paths, g_strdup("--enqueue"));
    forward_paths_to_flutter(self, paths);
  }

  g_ptr_array_unref(paths);
  g_strfreev(argv);

  g_application_command_line_set_exit_status(cmdline, 0);
  return 0;
}

// Implements GApplication::local_command_line.
static gboolean my_application_local_command_line(GApplication* application,
                                                  gchar*** arguments,
                                                  int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);

  // Capture entrypoint arguments for Flutter dart_entrypoint_arguments
  if (self->dart_entrypoint_arguments == nullptr) {
    self->dart_entrypoint_arguments = g_strdupv(*arguments + 1);
  }

  // Delegate to standard GApplication single-instance registration and IPC
  return G_APPLICATION_CLASS(my_application_parent_class)->local_command_line(
      application, arguments, exit_status);
}

// Implements GApplication::startup.
static void my_application_startup(GApplication* application) {
  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);

  if (self->mpris_player != nullptr) {
    mpris_player_dispose(self->mpris_player);
    g_clear_object(&self->mpris_player);
  }

  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);

  if (self->mpris_player != nullptr) {
    mpris_player_dispose(self->mpris_player);
    g_clear_object(&self->mpris_player);
  }

  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  g_clear_object(&self->single_instance_channel);

  if (self->pending_open_files != nullptr) {
    g_ptr_array_unref(self->pending_open_files);
    self->pending_open_files = nullptr;
  }

  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->open = my_application_open;
  G_APPLICATION_CLASS(klass)->command_line = my_application_command_line;
  G_APPLICATION_CLASS(klass)->local_command_line =
      my_application_local_command_line;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {
  self->dart_entrypoint_arguments = nullptr;
  self->window = nullptr;
  self->view = nullptr;
  self->single_instance_channel = nullptr;
  self->pending_open_files = g_ptr_array_new_with_free_func(g_free);
  self->mpris_player = nullptr;
}

MyApplication* my_application_new() {
  const gchar* app_id = "dev.mpvson.mpvson";
#ifdef APPLICATION_ID
  if (strlen(APPLICATION_ID) > 0) {
    app_id = APPLICATION_ID;
  }
#endif

  g_set_prgname(app_id);

  MyApplication* app = MY_APPLICATION(g_object_new(
      my_application_get_type(),
      "application-id", app_id,
      "flags", G_APPLICATION_HANDLES_OPEN | G_APPLICATION_HANDLES_COMMAND_LINE,
      nullptr));
  g_application_add_main_option(G_APPLICATION(app), "enqueue", 0,
                                G_OPTION_FLAG_NONE, G_OPTION_ARG_NONE,
                                "Add media to the queue", nullptr);
  return app;
}
