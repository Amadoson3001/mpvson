#include "mpris_player.h"

#include <gio/gio.h>
#include <string.h>

#define MPRIS_BUS_NAME "org.mpris.MediaPlayer2.dev.mpvson.mpvson"
#define MPRIS_OBJECT_PATH "/org/mpris/MediaPlayer2"
#define MPRIS_ROOT_INTERFACE "org.mpris.MediaPlayer2"
#define MPRIS_PLAYER_INTERFACE "org.mpris.MediaPlayer2.Player"
#define DBUS_PROPERTIES_INTERFACE "org.freedesktop.DBus.Properties"

#define PORTAL_BUS_NAME "org.freedesktop.portal.Desktop"
#define PORTAL_OBJECT_PATH "/org/freedesktop/portal/desktop"
#define PORTAL_INHIBIT_INTERFACE "org.freedesktop.portal.Inhibit"
#define PORTAL_REQUEST_INTERFACE "org.freedesktop.portal.Request"

#define SCREENSAVER_BUS_NAME "org.freedesktop.ScreenSaver"
#define SCREENSAVER_OBJECT_PATH "/org/freedesktop/ScreenSaver"
#define SCREENSAVER_INTERFACE "org.freedesktop.ScreenSaver"

static const gchar mpris_introspection_xml[] =
  "<node>"
  "  <interface name='org.mpris.MediaPlayer2'>"
  "    <method name='Raise'/>"
  "    <method name='Quit'/>"
  "    <property name='CanQuit' type='b' access='read'/>"
  "    <property name='CanRaise' type='b' access='read'/>"
  "    <property name='HasTrackList' type='b' access='read'/>"
  "    <property name='Identity' type='s' access='read'/>"
  "    <property name='SupportedUriSchemes' type='as' access='read'/>"
  "    <property name='SupportedMimeTypes' type='as' access='read'/>"
  "  </interface>"
  "  <interface name='org.mpris.MediaPlayer2.Player'>"
  "    <method name='Next'/>"
  "    <method name='Previous'/>"
  "    <method name='Pause'/>"
  "    <method name='PlayPause'/>"
  "    <method name='Stop'/>"
  "    <method name='Play'/>"
  "    <method name='Seek'>"
  "      <arg direction='in' name='Offset' type='x'/>"
  "    </method>"
  "    <method name='SetPosition'>"
  "      <arg direction='in' name='TrackId' type='o'/>"
  "      <arg direction='in' name='Position' type='x'/>"
  "    </method>"
  "    <method name='OpenUri'>"
  "      <arg direction='in' name='Uri' type='s'/>"
  "    </method>"
  "    <signal name='Seeked'>"
  "      <arg name='Position' type='x'/>"
  "    </signal>"
  "    <property name='PlaybackStatus' type='s' access='read'/>"
  "    <property name='LoopStatus' type='s' access='readwrite'/>"
  "    <property name='Rate' type='d' access='readwrite'/>"
  "    <property name='Shuffle' type='b' access='readwrite'/>"
  "    <property name='Metadata' type='a{sv}' access='read'/>"
  "    <property name='Volume' type='d' access='readwrite'/>"
  "    <property name='Position' type='x' access='read'/>"
  "    <property name='MinimumRate' type='d' access='read'/>"
  "    <property name='MaximumRate' type='d' access='read'/>"
  "    <property name='CanGoNext' type='b' access='read'/>"
  "    <property name='CanGoPrevious' type='b' access='read'/>"
  "    <property name='CanPlay' type='b' access='read'/>"
  "    <property name='CanPause' type='b' access='read'/>"
  "    <property name='CanSeek' type='b' access='read'/>"
  "    <property name='CanControl' type='b' access='read'/>"
  "  </interface>"
  "</node>";

struct _MprisPlayer {
  GObject parent_instance;

  GApplication* application;
  GtkWindow* window;
  FlBinaryMessenger* messenger;
  FlMethodChannel* media_controls_channel;
  FlMethodChannel* power_channel;

  guint dbus_owner_id;
  GDBusConnection* dbus_connection;
  guint root_reg_id;
  guint player_reg_id;
  GDBusNodeInfo* introspection_data;

  // Playback state
  gchar* playback_status;
  gdouble rate;
  gdouble volume;
  gchar* loop_status;
  gboolean shuffle;

  gint64 position_micros;
  gint64 duration_micros;
  gint64 last_position_update_time;

  gboolean can_play;
  gboolean can_pause;
  gboolean can_seek;
  gboolean can_go_next;
  gboolean can_go_previous;

  // Metadata
  gchar* meta_track_id;
  gchar* meta_title;
  gchar* meta_artist;
  gchar* meta_album;
  gchar* meta_album_artist;
  gchar* meta_genre;
  gchar* meta_art_url;
  gchar* meta_url;
  gint64 meta_length;

  // Power Management / Inhibit
  gboolean is_inhibited;
  gchar* inhibit_portal_handle;
  guint screensaver_cookie;
};

G_DEFINE_TYPE(MprisPlayer, mpris_player, G_TYPE_OBJECT)

static gint64 get_current_interpolated_position(MprisPlayer* self) {
  if (g_strcmp0(self->playback_status, "Playing") == 0 && self->rate > 0.0) {
    gint64 now = g_get_monotonic_time();
    gint64 elapsed = (gint64)((now - self->last_position_update_time) * self->rate);
    gint64 pos = self->position_micros + elapsed;
    if (self->duration_micros > 0 && pos > self->duration_micros) {
      pos = self->duration_micros;
    }
    if (pos < 0) {
      pos = 0;
    }
    return pos;
  }
  return self->position_micros;
}

static GVariant* build_metadata_dictionary(MprisPlayer* self) {
  GVariantBuilder builder;
  g_variant_builder_init(&builder, G_VARIANT_TYPE("a{sv}"));

  const gchar* track_id = (self->meta_track_id && self->meta_track_id[0])
      ? self->meta_track_id
      : "/dev/mpvson/mpvson/track/0";
  g_variant_builder_add(&builder, "{sv}", "mpris:trackid",
                        g_variant_new_object_path(track_id));

  if (self->meta_length > 0) {
    g_variant_builder_add(&builder, "{sv}", "mpris:length",
                          g_variant_new_int64(self->meta_length));
  } else if (self->duration_micros > 0) {
    g_variant_builder_add(&builder, "{sv}", "mpris:length",
                          g_variant_new_int64(self->duration_micros));
  }

  if (self->meta_title != nullptr && self->meta_title[0] != '\0') {
    g_variant_builder_add(&builder, "{sv}", "xesam:title",
                          g_variant_new_string(self->meta_title));
  }

  if (self->meta_artist != nullptr && self->meta_artist[0] != '\0') {
    GVariantBuilder artist_builder;
    g_variant_builder_init(&artist_builder, G_VARIANT_TYPE("as"));
    g_variant_builder_add(&artist_builder, "s", self->meta_artist);
    g_variant_builder_add(&builder, "{sv}", "xesam:artist",
                          g_variant_builder_end(&artist_builder));
  }

  if (self->meta_album != nullptr && self->meta_album[0] != '\0') {
    g_variant_builder_add(&builder, "{sv}", "xesam:album",
                          g_variant_new_string(self->meta_album));
  }

  if (self->meta_album_artist != nullptr && self->meta_album_artist[0] != '\0') {
    GVariantBuilder aa_builder;
    g_variant_builder_init(&aa_builder, G_VARIANT_TYPE("as"));
    g_variant_builder_add(&aa_builder, "s", self->meta_album_artist);
    g_variant_builder_add(&builder, "{sv}", "xesam:albumArtist",
                          g_variant_builder_end(&aa_builder));
  }

  if (self->meta_art_url != nullptr && self->meta_art_url[0] != '\0') {
    g_variant_builder_add(&builder, "{sv}", "mpris:artUrl",
                          g_variant_new_string(self->meta_art_url));
  }

  if (self->meta_url != nullptr && self->meta_url[0] != '\0') {
    g_variant_builder_add(&builder, "{sv}", "xesam:url",
                          g_variant_new_string(self->meta_url));
  }

  if (self->meta_genre != nullptr && self->meta_genre[0] != '\0') {
    GVariantBuilder genre_builder;
    g_variant_builder_init(&genre_builder, G_VARIANT_TYPE("as"));
    g_variant_builder_add(&genre_builder, "s", self->meta_genre);
    g_variant_builder_add(&builder, "{sv}", "xesam:genre",
                          g_variant_builder_end(&genre_builder));
  }

  return g_variant_builder_end(&builder);
}

static void emit_player_properties_changed(MprisPlayer* self, GVariant* changed_dict) {
  if (self->dbus_connection == nullptr) {
    if (changed_dict != nullptr) {
      g_variant_unref(changed_dict);
    }
    return;
  }

  GVariantBuilder invalidated_builder;
  g_variant_builder_init(&invalidated_builder, G_VARIANT_TYPE("as"));

  g_autoptr(GVariant) body = g_variant_new("(sa{sv}as)",
                                           MPRIS_PLAYER_INTERFACE,
                                           changed_dict,
                                           &invalidated_builder);

  g_dbus_connection_emit_signal(self->dbus_connection,
                                nullptr,
                                MPRIS_OBJECT_PATH,
                                DBUS_PROPERTIES_INTERFACE,
                                "PropertiesChanged",
                                body,
                                nullptr);
}

// -----------------------------------------------------------------------------
// D-Bus Root Interface Implementation (org.mpris.MediaPlayer2)
// -----------------------------------------------------------------------------

static void root_method_call(GDBusConnection* connection,
                             const gchar* sender,
                             const gchar* object_path,
                             const gchar* interface_name,
                             const gchar* method_name,
                             GVariant* parameters,
                             GDBusMethodInvocation* invocation,
                             gpointer user_data) {
  MprisPlayer* self = MPRIS_PLAYER(user_data);

  if (g_strcmp0(method_name, "Raise") == 0) {
    if (self->window != nullptr) {
      gtk_window_present(self->window);
    }
    if (self->media_controls_channel != nullptr) {
      fl_method_channel_invoke_method(self->media_controls_channel, "raise", nullptr, nullptr, nullptr, nullptr);
    }
    g_dbus_method_invocation_return_value(invocation, nullptr);
    return;
  }

  if (g_strcmp0(method_name, "Quit") == 0) {
    if (self->media_controls_channel != nullptr) {
      fl_method_channel_invoke_method(self->media_controls_channel, "quit", nullptr, nullptr, nullptr, nullptr);
    }
    if (self->application != nullptr) {
      g_application_quit(self->application);
    }
    g_dbus_method_invocation_return_value(invocation, nullptr);
    return;
  }

  g_dbus_method_invocation_return_error(invocation,
                                        G_DBUS_ERROR,
                                        G_DBUS_ERROR_UNKNOWN_METHOD,
                                        "Unknown method %s on interface %s",
                                        method_name, interface_name);
}

static GVariant* root_get_property(GDBusConnection* connection,
                                  const gchar* sender,
                                  const gchar* object_path,
                                  const gchar* interface_name,
                                  const gchar* property_name,
                                  GError** error,
                                  gpointer user_data) {
  if (g_strcmp0(property_name, "CanQuit") == 0) {
    return g_variant_new_boolean(TRUE);
  }
  if (g_strcmp0(property_name, "CanRaise") == 0) {
    return g_variant_new_boolean(TRUE);
  }
  if (g_strcmp0(property_name, "HasTrackList") == 0) {
    return g_variant_new_boolean(FALSE);
  }
  if (g_strcmp0(property_name, "Identity") == 0) {
    return g_variant_new_string("Mpvson");
  }
  if (g_strcmp0(property_name, "SupportedUriSchemes") == 0) {
    const gchar* schemes[] = {"file", "http", "https", nullptr};
    return g_variant_new_strv(schemes, -1);
  }
  if (g_strcmp0(property_name, "SupportedMimeTypes") == 0) {
    const gchar* mime_types[] = {
      "audio/mpeg",
      "audio/flac",
      "audio/wav",
      "audio/x-wav",
      "audio/mp4",
      "audio/x-m4a",
      "audio/aac",
      "audio/ogg",
      "audio/opus",
      "audio/x-ms-wma",
      "audio/x-aiff",
      "audio/x-ape",
      "video/mp4",
      "video/x-matroska",
      "video/x-msvideo",
      "video/avi",
      "video/webm",
      "video/quicktime",
      "video/x-flv",
      "video/x-ms-wmv",
      "video/x-m4v",
      "video/mp2t",
      "video/x-ms-vob",
      "video/ogg",
      "video/3gpp",
      nullptr
    };
    return g_variant_new_strv(mime_types, -1);
  }

  g_set_error(error, G_DBUS_ERROR, G_DBUS_ERROR_UNKNOWN_PROPERTY,
              "Unknown property %s", property_name);
  return nullptr;
}

// -----------------------------------------------------------------------------
// D-Bus Player Interface Implementation (org.mpris.MediaPlayer2.Player)
// -----------------------------------------------------------------------------

static void player_method_call(GDBusConnection* connection,
                              const gchar* sender,
                              const gchar* object_path,
                              const gchar* interface_name,
                              const gchar* method_name,
                              GVariant* parameters,
                              GDBusMethodInvocation* invocation,
                              gpointer user_data) {
  MprisPlayer* self = MPRIS_PLAYER(user_data);

  if (g_strcmp0(method_name, "Next") == 0) {
    if (self->media_controls_channel != nullptr) {
      fl_method_channel_invoke_method(self->media_controls_channel, "next", nullptr, nullptr, nullptr, nullptr);
    }
    g_dbus_method_invocation_return_value(invocation, nullptr);
    return;
  }

  if (g_strcmp0(method_name, "Previous") == 0) {
    if (self->media_controls_channel != nullptr) {
      fl_method_channel_invoke_method(self->media_controls_channel, "previous", nullptr, nullptr, nullptr, nullptr);
    }
    g_dbus_method_invocation_return_value(invocation, nullptr);
    return;
  }

  if (g_strcmp0(method_name, "Pause") == 0) {
    if (self->media_controls_channel != nullptr) {
      fl_method_channel_invoke_method(self->media_controls_channel, "pause", nullptr, nullptr, nullptr, nullptr);
    }
    g_dbus_method_invocation_return_value(invocation, nullptr);
    return;
  }

  if (g_strcmp0(method_name, "PlayPause") == 0) {
    if (self->media_controls_channel != nullptr) {
      fl_method_channel_invoke_method(self->media_controls_channel, "togglePlayPause", nullptr, nullptr, nullptr, nullptr);
    }
    g_dbus_method_invocation_return_value(invocation, nullptr);
    return;
  }

  if (g_strcmp0(method_name, "Stop") == 0) {
    if (self->media_controls_channel != nullptr) {
      fl_method_channel_invoke_method(self->media_controls_channel, "stop", nullptr, nullptr, nullptr, nullptr);
    }
    g_dbus_method_invocation_return_value(invocation, nullptr);
    return;
  }

  if (g_strcmp0(method_name, "Play") == 0) {
    if (self->media_controls_channel != nullptr) {
      fl_method_channel_invoke_method(self->media_controls_channel, "play", nullptr, nullptr, nullptr, nullptr);
    }
    g_dbus_method_invocation_return_value(invocation, nullptr);
    return;
  }

  if (g_strcmp0(method_name, "Seek") == 0) {
    gint64 offset = 0;
    g_variant_get(parameters, "(x)", &offset);
    if (self->media_controls_channel != nullptr) {
      gint64 current_pos = get_current_interpolated_position(self);
      gint64 target_pos = current_pos + offset;
      if (target_pos < 0) target_pos = 0;
      if (self->duration_micros > 0 && target_pos > self->duration_micros) {
        target_pos = self->duration_micros;
      }
      gint64 pos_ms = target_pos / 1000;

      g_autoptr(FlValue) args = fl_value_new_map();
      fl_value_set_string_take(args, "position", fl_value_new_int(pos_ms));
      fl_value_set_string_take(args, "positionMs", fl_value_new_int(pos_ms));
      fl_value_set_string_take(args, "offset", fl_value_new_int(offset));
      fl_method_channel_invoke_method(self->media_controls_channel, "seek", args, nullptr, nullptr, nullptr);
    }
    g_dbus_method_invocation_return_value(invocation, nullptr);
    return;
  }

  if (g_strcmp0(method_name, "SetPosition") == 0) {
    const gchar* track_id = nullptr;
    gint64 position = 0;
    g_variant_get(parameters, "(&ox)", &track_id, &position);
    if (self->media_controls_channel != nullptr) {
      gint64 pos_ms = position / 1000;
      g_autoptr(FlValue) args = fl_value_new_map();
      if (track_id != nullptr) {
        fl_value_set_string_take(args, "trackId", fl_value_new_string(track_id));
      }
      fl_value_set_string_take(args, "position", fl_value_new_int(pos_ms));
      fl_value_set_string_take(args, "positionMs", fl_value_new_int(pos_ms));
      fl_method_channel_invoke_method(self->media_controls_channel, "seek", args, nullptr, nullptr, nullptr);
    }
    g_dbus_method_invocation_return_value(invocation, nullptr);
    return;
  }

  if (g_strcmp0(method_name, "OpenUri") == 0) {
    const gchar* uri = nullptr;
    g_variant_get(parameters, "(&s)", &uri);
    if (self->media_controls_channel != nullptr && uri != nullptr) {
      g_autoptr(FlValue) args = fl_value_new_map();
      fl_value_set_string_take(args, "uri", fl_value_new_string(uri));
      fl_method_channel_invoke_method(self->media_controls_channel, "openUri", args, nullptr, nullptr, nullptr);
    }
    g_dbus_method_invocation_return_value(invocation, nullptr);
    return;
  }

  g_dbus_method_invocation_return_error(invocation,
                                        G_DBUS_ERROR,
                                        G_DBUS_ERROR_UNKNOWN_METHOD,
                                        "Unknown method %s on interface %s",
                                        method_name, interface_name);
}

static GVariant* player_get_property(GDBusConnection* connection,
                                    const gchar* sender,
                                    const gchar* object_path,
                                    const gchar* interface_name,
                                    const gchar* property_name,
                                    GError** error,
                                    gpointer user_data) {
  MprisPlayer* self = MPRIS_PLAYER(user_data);

  if (g_strcmp0(property_name, "PlaybackStatus") == 0) {
    return g_variant_new_string(self->playback_status ? self->playback_status : "Stopped");
  }
  if (g_strcmp0(property_name, "LoopStatus") == 0) {
    return g_variant_new_string(self->loop_status ? self->loop_status : "None");
  }
  if (g_strcmp0(property_name, "Rate") == 0) {
    return g_variant_new_double(self->rate);
  }
  if (g_strcmp0(property_name, "Shuffle") == 0) {
    return g_variant_new_boolean(self->shuffle);
  }
  if (g_strcmp0(property_name, "Metadata") == 0) {
    return build_metadata_dictionary(self);
  }
  if (g_strcmp0(property_name, "Volume") == 0) {
    return g_variant_new_double(self->volume);
  }
  if (g_strcmp0(property_name, "Position") == 0) {
    return g_variant_new_int64(get_current_interpolated_position(self));
  }
  if (g_strcmp0(property_name, "MinimumRate") == 0) {
    return g_variant_new_double(0.1);
  }
  if (g_strcmp0(property_name, "MaximumRate") == 0) {
    return g_variant_new_double(4.0);
  }
  if (g_strcmp0(property_name, "CanGoNext") == 0) {
    return g_variant_new_boolean(self->can_go_next);
  }
  if (g_strcmp0(property_name, "CanGoPrevious") == 0) {
    return g_variant_new_boolean(self->can_go_previous);
  }
  if (g_strcmp0(property_name, "CanPlay") == 0) {
    return g_variant_new_boolean(self->can_play);
  }
  if (g_strcmp0(property_name, "CanPause") == 0) {
    return g_variant_new_boolean(self->can_pause);
  }
  if (g_strcmp0(property_name, "CanSeek") == 0) {
    return g_variant_new_boolean(self->can_seek);
  }
  if (g_strcmp0(property_name, "CanControl") == 0) {
    return g_variant_new_boolean(TRUE);
  }

  g_set_error(error, G_DBUS_ERROR, G_DBUS_ERROR_UNKNOWN_PROPERTY,
              "Unknown property %s", property_name);
  return nullptr;
}

static gboolean player_set_property(GDBusConnection* connection,
                                    const gchar* sender,
                                    const gchar* object_path,
                                    const gchar* interface_name,
                                    const gchar* property_name,
                                    GVariant* value,
                                    GError** error,
                                    gpointer user_data) {
  MprisPlayer* self = MPRIS_PLAYER(user_data);

  if (g_strcmp0(property_name, "Rate") == 0) {
    self->rate = g_variant_get_double(value);
    if (self->media_controls_channel != nullptr) {
      g_autoptr(FlValue) args = fl_value_new_map();
      fl_value_set_string_take(args, "rate", fl_value_new_float(self->rate));
      fl_method_channel_invoke_method(self->media_controls_channel, "setRate", args, nullptr, nullptr, nullptr);
    }
    GVariantBuilder b;
    g_variant_builder_init(&b, G_VARIANT_TYPE("a{sv}"));
    g_variant_builder_add(&b, "{sv}", "Rate", g_variant_new_double(self->rate));
    emit_player_properties_changed(self, g_variant_builder_end(&b));
    return TRUE;
  }

  if (g_strcmp0(property_name, "Volume") == 0) {
    self->volume = g_variant_get_double(value);
    if (self->media_controls_channel != nullptr) {
      g_autoptr(FlValue) args = fl_value_new_map();
      fl_value_set_string_take(args, "volume", fl_value_new_float(self->volume));
      fl_method_channel_invoke_method(self->media_controls_channel, "setVolume", args, nullptr, nullptr, nullptr);
    }
    GVariantBuilder b;
    g_variant_builder_init(&b, G_VARIANT_TYPE("a{sv}"));
    g_variant_builder_add(&b, "{sv}", "Volume", g_variant_new_double(self->volume));
    emit_player_properties_changed(self, g_variant_builder_end(&b));
    return TRUE;
  }

  if (g_strcmp0(property_name, "LoopStatus") == 0) {
    g_free(self->loop_status);
    self->loop_status = g_strdup(g_variant_get_string(value, nullptr));
    if (self->media_controls_channel != nullptr) {
      g_autoptr(FlValue) args = fl_value_new_map();
      fl_value_set_string_take(args, "loopStatus", fl_value_new_string(self->loop_status));
      fl_method_channel_invoke_method(self->media_controls_channel, "setLoopStatus", args, nullptr, nullptr, nullptr);
    }
    GVariantBuilder b;
    g_variant_builder_init(&b, G_VARIANT_TYPE("a{sv}"));
    g_variant_builder_add(&b, "{sv}", "LoopStatus", g_variant_new_string(self->loop_status));
    emit_player_properties_changed(self, g_variant_builder_end(&b));
    return TRUE;
  }

  if (g_strcmp0(property_name, "Shuffle") == 0) {
    self->shuffle = g_variant_get_boolean(value);
    if (self->media_controls_channel != nullptr) {
      g_autoptr(FlValue) args = fl_value_new_map();
      fl_value_set_string_take(args, "shuffle", fl_value_new_bool(self->shuffle));
      fl_method_channel_invoke_method(self->media_controls_channel, "setShuffle", args, nullptr, nullptr, nullptr);
    }
    GVariantBuilder b;
    g_variant_builder_init(&b, G_VARIANT_TYPE("a{sv}"));
    g_variant_builder_add(&b, "{sv}", "Shuffle", g_variant_new_boolean(self->shuffle));
    emit_player_properties_changed(self, g_variant_builder_end(&b));
    return TRUE;
  }

  g_set_error(error, G_DBUS_ERROR, G_DBUS_ERROR_PROPERTY_READ_ONLY,
              "Property %s is read-only", property_name);
  return FALSE;
}

static const GDBusInterfaceVTable root_vtable = {
  root_method_call,
  root_get_property,
  nullptr,
  {0}
};

static const GDBusInterfaceVTable player_vtable = {
  player_method_call,
  player_get_property,
  player_set_property,
  {0}
};

// -----------------------------------------------------------------------------
// D-Bus Registration & Lifecycle
// -----------------------------------------------------------------------------

static void on_bus_acquired(GDBusConnection* connection,
                            const gchar* name,
                            gpointer user_data) {
  MprisPlayer* self = MPRIS_PLAYER(user_data);
  self->dbus_connection = G_DBUS_CONNECTION(g_object_ref(connection));

  g_autoptr(GError) error = nullptr;
  self->introspection_data = g_dbus_node_info_new_for_xml(mpris_introspection_xml, &error);
  if (self->introspection_data == nullptr) {
    g_warning("MPRIS: Failed to parse introspection XML: %s", error->message);
    return;
  }

  GDBusInterfaceInfo* root_iface =
      g_dbus_node_info_lookup_interface(self->introspection_data, MPRIS_ROOT_INTERFACE);
  if (root_iface != nullptr) {
    self->root_reg_id = g_dbus_connection_register_object(
        connection,
        MPRIS_OBJECT_PATH,
        root_iface,
        &root_vtable,
        self,
        nullptr,
        &error);
    if (self->root_reg_id == 0) {
      g_warning("MPRIS: Failed to register root interface: %s", error->message);
      g_clear_error(&error);
    }
  }

  GDBusInterfaceInfo* player_iface =
      g_dbus_node_info_lookup_interface(self->introspection_data, MPRIS_PLAYER_INTERFACE);
  if (player_iface != nullptr) {
    self->player_reg_id = g_dbus_connection_register_object(
        connection,
        MPRIS_OBJECT_PATH,
        player_iface,
        &player_vtable,
        self,
        nullptr,
        &error);
    if (self->player_reg_id == 0) {
      g_warning("MPRIS: Failed to register player interface: %s", error->message);
      g_clear_error(&error);
    }
  }
}

static void on_name_acquired(GDBusConnection* connection,
                             const gchar* name,
                             gpointer user_data) {
  g_debug("MPRIS: Successfully acquired D-Bus name: %s", name);
}

static void on_name_lost(GDBusConnection* connection,
                          const gchar* name,
                          gpointer user_data) {
  g_debug("MPRIS: Lost D-Bus name: %s", name);
}

// -----------------------------------------------------------------------------
// Power Management (XDG Inhibit portal + ScreenSaver fallback)
// -----------------------------------------------------------------------------

void mpris_player_inhibit_power(MprisPlayer* self, const gchar* reason) {
  if (self->is_inhibited) {
    return;
  }
  if (self->dbus_connection == nullptr) {
    return;
  }

  const gchar* effective_reason = (reason && reason[0]) ? reason : "Playing video";

  // Flags: 4 = Suspend inhibit, 8 = Idle / Screensaver blanking inhibit
  guint32 flags = 12;

  GVariantBuilder opt_builder;
  g_variant_builder_init(&opt_builder, G_VARIANT_TYPE("a{sv}"));
  g_variant_builder_add(&opt_builder, "{sv}", "reason", g_variant_new_string(effective_reason));

  g_autoptr(GError) portal_error = nullptr;
  g_autoptr(GVariant) result = g_dbus_connection_call_sync(
      self->dbus_connection,
      PORTAL_BUS_NAME,
      PORTAL_OBJECT_PATH,
      PORTAL_INHIBIT_INTERFACE,
      "Inhibit",
      g_variant_new("(sua{sv})", "", flags, &opt_builder),
      G_VARIANT_TYPE("(o)"),
      G_DBUS_CALL_FLAGS_NONE,
      1000,
      nullptr,
      &portal_error);

  if (result != nullptr) {
    const gchar* handle = nullptr;
    g_variant_get(result, "(&o)", &handle);
    if (handle != nullptr && handle[0] != '\0') {
      g_free(self->inhibit_portal_handle);
      self->inhibit_portal_handle = g_strdup(handle);
      self->is_inhibited = TRUE;
      return;
    }
  }

  // Fallback to org.freedesktop.ScreenSaver
  g_autoptr(GError) ss_error = nullptr;
  g_autoptr(GVariant) ss_result = g_dbus_connection_call_sync(
      self->dbus_connection,
      SCREENSAVER_BUS_NAME,
      SCREENSAVER_OBJECT_PATH,
      SCREENSAVER_INTERFACE,
      "Inhibit",
      g_variant_new("(ss)", "dev.mpvson.mpvson", effective_reason),
      G_VARIANT_TYPE("(u)"),
      G_DBUS_CALL_FLAGS_NONE,
      1000,
      nullptr,
      &ss_error);

  if (ss_result != nullptr) {
    guint32 cookie = 0;
    g_variant_get(ss_result, "(u)", &cookie);
    self->screensaver_cookie = cookie;
    self->is_inhibited = TRUE;
  }
}

void mpris_player_uninhibit_power(MprisPlayer* self) {
  if (!self->is_inhibited) {
    return;
  }
  if (self->dbus_connection == nullptr) {
    self->is_inhibited = FALSE;
    return;
  }

  if (self->inhibit_portal_handle != nullptr) {
    g_dbus_connection_call_sync(
        self->dbus_connection,
        PORTAL_BUS_NAME,
        self->inhibit_portal_handle,
        PORTAL_REQUEST_INTERFACE,
        "Close",
        nullptr,
        nullptr,
        G_DBUS_CALL_FLAGS_NONE,
        1000,
        nullptr,
        nullptr);
    g_clear_pointer(&self->inhibit_portal_handle, g_free);
  }

  if (self->screensaver_cookie != 0) {
    g_dbus_connection_call_sync(
        self->dbus_connection,
        SCREENSAVER_BUS_NAME,
        SCREENSAVER_OBJECT_PATH,
        SCREENSAVER_INTERFACE,
        "UnInhibit",
        g_variant_new("(u)", self->screensaver_cookie),
        nullptr,
        G_DBUS_CALL_FLAGS_NONE,
        1000,
        nullptr,
        nullptr);
    self->screensaver_cookie = 0;
  }

  self->is_inhibited = FALSE;
}

void mpris_player_emit_seeked(MprisPlayer* self, gint64 position_micros) {
  self->position_micros = position_micros;
  self->last_position_update_time = g_get_monotonic_time();

  if (self->dbus_connection != nullptr) {
    g_autoptr(GVariant) body = g_variant_new("(x)", position_micros);
    g_dbus_connection_emit_signal(self->dbus_connection,
                                  nullptr,
                                  MPRIS_OBJECT_PATH,
                                  MPRIS_PLAYER_INTERFACE,
                                  "Seeked",
                                  body,
                                  nullptr);
  }
}

// -----------------------------------------------------------------------------
// MethodChannel Handler (Flutter -> Native Media Controls & Power Bridge)
// -----------------------------------------------------------------------------

static gint64 parse_int_or_duration(FlValue* value) {
  if (value == nullptr) {
    return 0;
  }
  if (fl_value_get_type(value) == FL_VALUE_TYPE_INT) {
    return fl_value_get_int(value);
  }
  if (fl_value_get_type(value) == FL_VALUE_TYPE_FLOAT) {
    return (gint64)fl_value_get_float(value);
  }
  return 0;
}

static void handle_update_playback_state(MprisPlayer* self, FlValue* args) {
  if (args == nullptr) {
    return;
  }

  GVariantBuilder changed;
  g_variant_builder_init(&changed, G_VARIANT_TYPE("a{sv}"));

  if (fl_value_get_type(args) == FL_VALUE_TYPE_MAP) {
    FlValue* status_val = fl_value_lookup_string(args, "status");
    if (status_val != nullptr) {
      const gchar* new_status = "Stopped";
      if (fl_value_get_type(status_val) == FL_VALUE_TYPE_STRING) {
        const gchar* raw = fl_value_get_string(status_val);
        if (g_ascii_strcasecmp(raw, "playing") == 0) {
          new_status = "Playing";
        } else if (g_ascii_strcasecmp(raw, "paused") == 0) {
          new_status = "Paused";
        } else {
          new_status = "Stopped";
        }
      } else if (fl_value_get_type(status_val) == FL_VALUE_TYPE_INT) {
        gint64 idx = fl_value_get_int(status_val);
        if (idx == 2) {
          new_status = "Playing";
        } else if (idx == 3) {
          new_status = "Paused";
        } else {
          new_status = "Stopped";
        }
      }

      if (g_strcmp0(self->playback_status, new_status) != 0) {
        g_free(self->playback_status);
        self->playback_status = g_strdup(new_status);
        g_variant_builder_add(&changed, "{sv}", "PlaybackStatus",
                              g_variant_new_string(self->playback_status));
      }
    }

    FlValue* rate_val = fl_value_lookup_string(args, "playbackRate");
    if (rate_val == nullptr) {
      rate_val = fl_value_lookup_string(args, "rate");
    }
    if (rate_val != nullptr) {
      gdouble new_rate = 1.0;
      if (fl_value_get_type(rate_val) == FL_VALUE_TYPE_FLOAT) {
        new_rate = fl_value_get_float(rate_val);
      } else if (fl_value_get_type(rate_val) == FL_VALUE_TYPE_INT) {
        new_rate = (gdouble)fl_value_get_int(rate_val);
      }
      if (new_rate != self->rate) {
        self->rate = new_rate;
        g_variant_builder_add(&changed, "{sv}", "Rate",
                              g_variant_new_double(self->rate));
      }
    }

    FlValue* pos_micros_val = fl_value_lookup_string(args, "positionMicros");
    FlValue* pos_ms_val = fl_value_lookup_string(args, "positionMs");
    FlValue* pos_val = fl_value_lookup_string(args, "position");
    if (pos_micros_val != nullptr) {
      self->position_micros = parse_int_or_duration(pos_micros_val);
    } else if (pos_ms_val != nullptr) {
      self->position_micros = parse_int_or_duration(pos_ms_val) * 1000;
    } else if (pos_val != nullptr) {
      gint64 raw_pos = parse_int_or_duration(pos_val);
      // If position is in milliseconds (< 100 hours in ms is < 3.6e8)
      self->position_micros = raw_pos * 1000;
    }
    self->last_position_update_time = g_get_monotonic_time();

    FlValue* dur_micros_val = fl_value_lookup_string(args, "durationMicros");
    FlValue* dur_ms_val = fl_value_lookup_string(args, "durationMs");
    FlValue* dur_val = fl_value_lookup_string(args, "duration");
    if (dur_micros_val != nullptr) {
      self->duration_micros = parse_int_or_duration(dur_micros_val);
    } else if (dur_ms_val != nullptr) {
      self->duration_micros = parse_int_or_duration(dur_ms_val) * 1000;
    } else if (dur_val != nullptr) {
      gint64 raw_dur = parse_int_or_duration(dur_val);
      self->duration_micros = raw_dur * 1000;
    }
  } else if (fl_value_get_type(args) == FL_VALUE_TYPE_STRING) {
    const gchar* raw = fl_value_get_string(args);
    const gchar* new_status = "Stopped";
    if (g_ascii_strcasecmp(raw, "playing") == 0) {
      new_status = "Playing";
    } else if (g_ascii_strcasecmp(raw, "paused") == 0) {
      new_status = "Paused";
    }
    if (g_strcmp0(self->playback_status, new_status) != 0) {
      g_free(self->playback_status);
      self->playback_status = g_strdup(new_status);
      g_variant_builder_add(&changed, "{sv}", "PlaybackStatus",
                            g_variant_new_string(self->playback_status));
    }
  }

  emit_player_properties_changed(self, g_variant_builder_end(&changed));
}

static void handle_update_metadata(MprisPlayer* self, FlValue* args) {
  if (args == nullptr || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) {
    return;
  }

  FlValue* track_val = fl_value_lookup_string(args, "trackId");
  if (track_val != nullptr && fl_value_get_type(track_val) == FL_VALUE_TYPE_STRING &&
      g_variant_is_object_path(fl_value_get_string(track_val))) {
    g_free(self->meta_track_id);
    self->meta_track_id = g_strdup(fl_value_get_string(track_val));
  }
  FlValue* title_val = fl_value_lookup_string(args, "title");
  if (title_val != nullptr && fl_value_get_type(title_val) == FL_VALUE_TYPE_STRING) {
    g_free(self->meta_title);
    self->meta_title = g_strdup(fl_value_get_string(title_val));
  }

  FlValue* artist_val = fl_value_lookup_string(args, "artist");
  if (artist_val != nullptr && fl_value_get_type(artist_val) == FL_VALUE_TYPE_STRING) {
    g_free(self->meta_artist);
    self->meta_artist = g_strdup(fl_value_get_string(artist_val));
  }

  FlValue* album_val = fl_value_lookup_string(args, "album");
  if (album_val != nullptr && fl_value_get_type(album_val) == FL_VALUE_TYPE_STRING) {
    g_free(self->meta_album);
    self->meta_album = g_strdup(fl_value_get_string(album_val));
  }

  FlValue* album_artist_val = fl_value_lookup_string(args, "albumArtist");
  if (album_artist_val == nullptr) {
    album_artist_val = fl_value_lookup_string(args, "album_artist");
  }
  if (album_artist_val != nullptr && fl_value_get_type(album_artist_val) == FL_VALUE_TYPE_STRING) {
    g_free(self->meta_album_artist);
    self->meta_album_artist = g_strdup(fl_value_get_string(album_artist_val));
  }

  FlValue* genre_val = fl_value_lookup_string(args, "genre");
  if (genre_val != nullptr && fl_value_get_type(genre_val) == FL_VALUE_TYPE_STRING) {
    g_free(self->meta_genre);
    self->meta_genre = g_strdup(fl_value_get_string(genre_val));
  }

  FlValue* art_val = fl_value_lookup_string(args, "artworkUri");
  if (art_val == nullptr) {
    art_val = fl_value_lookup_string(args, "artworkPath");
  }
  if (art_val == nullptr) {
    art_val = fl_value_lookup_string(args, "artUrl");
  }
  if (art_val == nullptr) {
    art_val = fl_value_lookup_string(args, "artwork");
  }
  if (art_val != nullptr && fl_value_get_type(art_val) == FL_VALUE_TYPE_STRING) {
    g_free(self->meta_art_url);
    self->meta_art_url = g_strdup(fl_value_get_string(art_val));
  }

  FlValue* url_val = fl_value_lookup_string(args, "url");
  if (url_val == nullptr) {
    url_val = fl_value_lookup_string(args, "path");
  }
  if (url_val != nullptr && fl_value_get_type(url_val) == FL_VALUE_TYPE_STRING) {
    g_free(self->meta_url);
    self->meta_url = g_strdup(fl_value_get_string(url_val));
  }

  FlValue* dur_micros = fl_value_lookup_string(args, "durationMicros");
  FlValue* dur_ms = fl_value_lookup_string(args, "durationMs");
  FlValue* dur_val = fl_value_lookup_string(args, "duration");
  if (dur_micros != nullptr) {
    self->meta_length = parse_int_or_duration(dur_micros);
  } else if (dur_ms != nullptr) {
    self->meta_length = parse_int_or_duration(dur_ms) * 1000;
  } else if (dur_val != nullptr) {
    self->meta_length = parse_int_or_duration(dur_val) * 1000;
  }

  GVariantBuilder b;
  g_variant_builder_init(&b, G_VARIANT_TYPE("a{sv}"));
  g_variant_builder_add_value(&b, g_variant_new_dict_entry(
      g_variant_new_string("Metadata"),
      g_variant_new_variant(build_metadata_dictionary(self))));
  emit_player_properties_changed(self, g_variant_builder_end(&b));
}

static void handle_clear_metadata(MprisPlayer* self) {
  g_clear_pointer(&self->meta_title, g_free);
  g_clear_pointer(&self->meta_artist, g_free);
  g_clear_pointer(&self->meta_album, g_free);
  g_clear_pointer(&self->meta_album_artist, g_free);
  g_clear_pointer(&self->meta_genre, g_free);
  g_clear_pointer(&self->meta_art_url, g_free);
  g_clear_pointer(&self->meta_url, g_free);
  self->meta_length = 0;

  GVariantBuilder b;
  g_variant_builder_init(&b, G_VARIANT_TYPE("a{sv}"));
  g_variant_builder_add_value(&b, g_variant_new_dict_entry(
      g_variant_new_string("Metadata"),
      g_variant_new_variant(build_metadata_dictionary(self))));
  emit_player_properties_changed(self, g_variant_builder_end(&b));
}

static void handle_update_capabilities(MprisPlayer* self, FlValue* args) {
  if (args == nullptr || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) {
    return;
  }

  GVariantBuilder changed;
  g_variant_builder_init(&changed, G_VARIANT_TYPE("a{sv}"));

  FlValue* can_play_val = fl_value_lookup_string(args, "canPlay");
  if (can_play_val != nullptr && fl_value_get_type(can_play_val) == FL_VALUE_TYPE_BOOL) {
    gboolean val = fl_value_get_bool(can_play_val);
    if (val != self->can_play) {
      self->can_play = val;
      g_variant_builder_add(&changed, "{sv}", "CanPlay", g_variant_new_boolean(self->can_play));
    }
  }

  FlValue* can_pause_val = fl_value_lookup_string(args, "canPause");
  if (can_pause_val != nullptr && fl_value_get_type(can_pause_val) == FL_VALUE_TYPE_BOOL) {
    gboolean val = fl_value_get_bool(can_pause_val);
    if (val != self->can_pause) {
      self->can_pause = val;
      g_variant_builder_add(&changed, "{sv}", "CanPause", g_variant_new_boolean(self->can_pause));
    }
  }

  FlValue* can_seek_val = fl_value_lookup_string(args, "canSeek");
  if (can_seek_val != nullptr && fl_value_get_type(can_seek_val) == FL_VALUE_TYPE_BOOL) {
    gboolean val = fl_value_get_bool(can_seek_val);
    if (val != self->can_seek) {
      self->can_seek = val;
      g_variant_builder_add(&changed, "{sv}", "CanSeek", g_variant_new_boolean(self->can_seek));
    }
  }

  FlValue* can_next_val = fl_value_lookup_string(args, "canGoNext");
  if (can_next_val != nullptr && fl_value_get_type(can_next_val) == FL_VALUE_TYPE_BOOL) {
    gboolean val = fl_value_get_bool(can_next_val);
    if (val != self->can_go_next) {
      self->can_go_next = val;
      g_variant_builder_add(&changed, "{sv}", "CanGoNext", g_variant_new_boolean(self->can_go_next));
    }
  }

  FlValue* can_prev_val = fl_value_lookup_string(args, "canGoPrevious");
  if (can_prev_val != nullptr && fl_value_get_type(can_prev_val) == FL_VALUE_TYPE_BOOL) {
    gboolean val = fl_value_get_bool(can_prev_val);
    if (val != self->can_go_previous) {
      self->can_go_previous = val;
      g_variant_builder_add(&changed, "{sv}", "CanGoPrevious", g_variant_new_boolean(self->can_go_previous));
    }
  }

  emit_player_properties_changed(self, g_variant_builder_end(&changed));
}

static void handle_set_keep_awake(MprisPlayer* self, FlValue* args) {
  gboolean enable = FALSE;
  const gchar* reason = "Playing video";

  if (args != nullptr) {
    if (fl_value_get_type(args) == FL_VALUE_TYPE_BOOL) {
      enable = fl_value_get_bool(args);
    } else if (fl_value_get_type(args) == FL_VALUE_TYPE_MAP) {
      FlValue* enable_val = fl_value_lookup_string(args, "enable");
      if (enable_val == nullptr) {
        enable_val = fl_value_lookup_string(args, "inhibit");
      }
      if (enable_val == nullptr) {
        enable_val = fl_value_lookup_string(args, "keepAwake");
      }
      if (enable_val != nullptr && fl_value_get_type(enable_val) == FL_VALUE_TYPE_BOOL) {
        enable = fl_value_get_bool(enable_val);
      }
      FlValue* reason_val = fl_value_lookup_string(args, "reason");
      if (reason_val != nullptr && fl_value_get_type(reason_val) == FL_VALUE_TYPE_STRING) {
        reason = fl_value_get_string(reason_val);
      }
    }
  }

  if (enable) {
    mpris_player_inhibit_power(self, reason);
  } else {
    mpris_player_uninhibit_power(self);
  }
}

static void media_controls_method_call_cb(FlMethodChannel* channel,
                                          FlMethodCall* method_call,
                                          gpointer user_data) {
  MprisPlayer* self = MPRIS_PLAYER(user_data);
  const gchar* method = fl_method_call_get_name(method_call);
  FlValue* args = fl_method_call_get_args(method_call);

  if (g_strcmp0(method, "updatePlaybackState") == 0 ||
      g_strcmp0(method, "setPlaybackState") == 0 ||
      g_strcmp0(method, "updatePlaybackStatus") == 0 ||
      g_strcmp0(method, "setPlaybackStatus") == 0) {
    handle_update_playback_state(self, args);
    fl_method_call_respond_success(method_call, nullptr, nullptr);
    return;
  }

  if (g_strcmp0(method, "updateTimeline") == 0 ||
      g_strcmp0(method, "setTimeline") == 0) {
    handle_update_playback_state(self, args);
    fl_method_call_respond_success(method_call, nullptr, nullptr);
    return;
  }

  if (g_strcmp0(method, "updateMetadata") == 0 ||
      g_strcmp0(method, "setMetadata") == 0) {
    handle_update_metadata(self, args);
    fl_method_call_respond_success(method_call, nullptr, nullptr);
    return;
  }

  if (g_strcmp0(method, "clearMetadata") == 0 ||
      g_strcmp0(method, "clear") == 0) {
    handle_clear_metadata(self);
    fl_method_call_respond_success(method_call, nullptr, nullptr);
    return;
  }

  if (g_strcmp0(method, "updateCapabilities") == 0 ||
      g_strcmp0(method, "setCapabilities") == 0) {
    handle_update_capabilities(self, args);
    fl_method_call_respond_success(method_call, nullptr, nullptr);
    return;
  }

  if (g_strcmp0(method, "setKeepAwake") == 0 ||
      g_strcmp0(method, "setInhibit") == 0 ||
      g_strcmp0(method, "inhibitSleep") == 0) {
    handle_set_keep_awake(self, args);
    fl_method_call_respond_success(method_call, nullptr, nullptr);
    return;
  }

  if (g_strcmp0(method, "seeked") == 0) {
    if (args != nullptr && fl_value_get_type(args) == FL_VALUE_TYPE_INT) {
      mpris_player_emit_seeked(self, fl_value_get_int(args) * 1000);
    }
    fl_method_call_respond_success(method_call, nullptr, nullptr);
    return;
  }

  if (g_strcmp0(method, "openDefaultAppsSettings") == 0) {
    g_spawn_command_line_async("gnome-control-center default-apps", nullptr);
    g_autoptr(FlValue) res = fl_value_new_bool(TRUE);
    fl_method_call_respond_success(method_call, res, nullptr);
    return;
  }

  fl_method_call_respond_success(method_call, nullptr, nullptr);
}

static void power_method_call_cb(FlMethodChannel* channel,
                                 FlMethodCall* method_call,
                                 gpointer user_data) {
  MprisPlayer* self = MPRIS_PLAYER(user_data);
  const gchar* method = fl_method_call_get_name(method_call);
  FlValue* args = fl_method_call_get_args(method_call);

  if (g_strcmp0(method, "setKeepAwake") == 0 ||
      g_strcmp0(method, "setInhibit") == 0) {
    handle_set_keep_awake(self, args);
    fl_method_call_respond_success(method_call, nullptr, nullptr);
    return;
  }

  if (g_strcmp0(method, "getIsAwakeInhibited") == 0 ||
      g_strcmp0(method, "isInhibited") == 0) {
    g_autoptr(FlValue) res = fl_value_new_bool(self->is_inhibited);
    fl_method_call_respond_success(method_call, res, nullptr);
    return;
  }

  fl_method_call_respond_success(method_call, nullptr, nullptr);
}

// -----------------------------------------------------------------------------
// Initialization & Disposal
// -----------------------------------------------------------------------------

static void mpris_player_init(MprisPlayer* self) {
  self->playback_status = g_strdup("Stopped");
  self->rate = 1.0;
  self->volume = 1.0;
  self->loop_status = g_strdup("None");
  self->shuffle = FALSE;

  self->can_play = TRUE;
  self->can_pause = TRUE;
  self->can_seek = TRUE;
  self->can_go_next = TRUE;
  self->can_go_previous = TRUE;

  self->meta_track_id = g_strdup("/dev/mpvson/mpvson/track/0");
}

static void mpris_player_dispose_internal(GObject* object) {
  MprisPlayer* self = MPRIS_PLAYER(object);
  mpris_player_dispose(self);
  G_OBJECT_CLASS(mpris_player_parent_class)->dispose(object);
}

static void mpris_player_class_init(MprisPlayerClass* klass) {
  G_OBJECT_CLASS(klass)->dispose = mpris_player_dispose_internal;
}

MprisPlayer* mpris_player_new(GApplication* application,
                             GtkWindow* window,
                             FlBinaryMessenger* messenger) {
  MprisPlayer* self = MPRIS_PLAYER(g_object_new(mpris_player_get_type(), nullptr));
  self->application = application;
  self->window = window;
  self->messenger = messenger;

  if (messenger != nullptr) {
    g_autoptr(FlStandardMethodCodec) codec1 = fl_standard_method_codec_new();
    self->media_controls_channel = fl_method_channel_new(
        messenger, "mpvson/media_controls", FL_METHOD_CODEC(codec1));
    fl_method_channel_set_method_call_handler(self->media_controls_channel,
                                              media_controls_method_call_cb,
                                              self,
                                              nullptr);

    g_autoptr(FlStandardMethodCodec) codec2 = fl_standard_method_codec_new();
    self->power_channel = fl_method_channel_new(
        messenger, "mpvson/power", FL_METHOD_CODEC(codec2));
    fl_method_channel_set_method_call_handler(self->power_channel,
                                              power_method_call_cb,
                                              self,
                                              nullptr);
  }

  return self;
}

void mpris_player_start(MprisPlayer* self) {
  if (self->dbus_owner_id != 0) {
    return;
  }

  self->dbus_owner_id = g_bus_own_name(
      G_BUS_TYPE_SESSION,
      MPRIS_BUS_NAME,
      G_BUS_NAME_OWNER_FLAGS_REPLACE,
      on_bus_acquired,
      on_name_acquired,
      on_name_lost,
      self,
      nullptr);
}

void mpris_player_dispose(MprisPlayer* self) {
  mpris_player_uninhibit_power(self);

  if (self->dbus_owner_id != 0) {
    g_bus_unown_name(self->dbus_owner_id);
    self->dbus_owner_id = 0;
  }

  if (self->dbus_connection != nullptr) {
    if (self->root_reg_id != 0) {
      g_dbus_connection_unregister_object(self->dbus_connection, self->root_reg_id);
      self->root_reg_id = 0;
    }
    if (self->player_reg_id != 0) {
      g_dbus_connection_unregister_object(self->dbus_connection, self->player_reg_id);
      self->player_reg_id = 0;
    }
    g_clear_object(&self->dbus_connection);
  }

  if (self->introspection_data != nullptr) {
    g_dbus_node_info_unref(self->introspection_data);
    self->introspection_data = nullptr;
  }

  g_clear_object(&self->media_controls_channel);
  g_clear_object(&self->power_channel);

  g_clear_pointer(&self->playback_status, g_free);
  g_clear_pointer(&self->loop_status, g_free);
  g_clear_pointer(&self->meta_track_id, g_free);
  g_clear_pointer(&self->meta_title, g_free);
  g_clear_pointer(&self->meta_artist, g_free);
  g_clear_pointer(&self->meta_album, g_free);
  g_clear_pointer(&self->meta_album_artist, g_free);
  g_clear_pointer(&self->meta_genre, g_free);
  g_clear_pointer(&self->meta_art_url, g_free);
  g_clear_pointer(&self->meta_url, g_free);
}
