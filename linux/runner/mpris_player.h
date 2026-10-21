#ifndef MPRIS_PLAYER_H_
#define MPRIS_PLAYER_H_

#include <gtk/gtk.h>
#include <flutter_linux/flutter_linux.h>

G_BEGIN_DECLS

G_DECLARE_FINAL_TYPE(MprisPlayer, mpris_player, MPRIS, PLAYER, GObject)

/**
 * mpris_player_new:
 * @application: The owning GApplication / MyApplication.
 * @window: The primary GtkWindow for raising/focusing.
 * @messenger: The Flutter binary messenger for method channel communication.
 *
 * Creates a new MPRIS D-Bus player instance.
 */
MprisPlayer* mpris_player_new(GApplication* application,
                             GtkWindow* window,
                             FlBinaryMessenger* messenger);

/**
 * mpris_player_start:
 * @self: An #MprisPlayer.
 *
 * Registers the org.mpris.MediaPlayer2.dev.mpvson.mpvson D-Bus name and
 * exports root and player interfaces on the session bus.
 */
void mpris_player_start(MprisPlayer* self);

/**
 * mpris_player_inhibit_power:
 * @self: An #MprisPlayer.
 * @reason: Human-readable reason for sleep inhibition (e.g. "Playing video").
 *
 * Inhibits system idle and screensaver blanking via the XDG Inhibit portal.
 */
void mpris_player_inhibit_power(MprisPlayer* self, const gchar* reason);

/**
 * mpris_player_uninhibit_power:
 * @self: An #MprisPlayer.
 *
 * Releases any active sleep/screensaver inhibit lock.
 */
void mpris_player_uninhibit_power(MprisPlayer* self);

/**
 * mpris_player_emit_seeked:
 * @self: An #MprisPlayer.
 * @position_micros: New position in microseconds.
 *
 * Emits the MPRIS Seeked signal.
 */
void mpris_player_emit_seeked(MprisPlayer* self, gint64 position_micros);

/**
 * mpris_player_dispose:
 * @self: An #MprisPlayer.
 *
 * Unregisters D-Bus objects, releases inhibit locks, and cleans up resources.
 */
void mpris_player_dispose(MprisPlayer* self);

G_END_DECLS

#endif  // MPRIS_PLAYER_H_
