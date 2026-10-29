import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import '../../player/player_controller.dart';
import '../../../domain/models/media_entry.dart';
import '../tokens/colors.dart';

/// Follows the active media and animates its accessible artwork color.
class MediaAccentScope extends StatefulWidget {
  const MediaAccentScope({
    super.key,
    required this.controller,
    required this.child,
    this.entryOverride,
  });
  final PlayerController controller;
  final Widget child;
  final MediaEntry? entryOverride;
  @override
  State<MediaAccentScope> createState() => _MediaAccentScopeState();
}

class _MediaAccentScopeState extends State<MediaAccentScope> {
  String? _path;
  Color _color = AppColors.lamp;
  MediaAccentPalette _palette = const MediaAccentPalette();
  int _generation = 0;
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
    _changed();
  }

  @override
  void didUpdateWidget(MediaAccentScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_changed);
      widget.controller.addListener(_changed);
      _path = '';
      _changed();
    } else if (oldWidget.entryOverride?.path != widget.entryOverride?.path) {
      _path = '';
      _changed();
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    _generation++;
    super.dispose();
  }

  void _changed() {
    final entry = widget.entryOverride ?? widget.controller.current;
    if (entry?.path == _path) return;
    _path = entry?.path;
    final generation = ++_generation;
    if (entry == null) {
      if (mounted) {
        setState(() {
          _color = AppColors.lamp;
          _palette = const MediaAccentPalette();
        });
      }
      return;
    }
    _extract(entry, generation);
  }

  Future<void> _extract(MediaEntry entry, int generation) async {
    Color dominant = AppColors.lamp;
    Color vibrant = AppColors.gold;
    Color muted = AppColors.layer;
    try {
      final thumbnail = await widget.controller.loadThumbnail(entry);
      if (thumbnail != null) {
        final codec = await ui.instantiateImageCodec(
          thumbnail.bytes,
          targetWidth: 48,
          targetHeight: 48,
        );
        final frame = await codec.getNextFrame();
        final data = await frame.image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        );
        frame.image.dispose();
        codec.dispose();
        if (data != null) {
          final bytes = data.buffer.asUint8List();
          final bins = <int, List<int>>{};
          for (var i = 0; i + 3 < bytes.length; i += 4) {
            if (bytes[i + 3] < 128) continue;
            final r = bytes[i], g = bytes[i + 1], b = bytes[i + 2];
            final max = [r, g, b].reduce((a, b) => a > b ? a : b);
            final min = [r, g, b].reduce((a, b) => a < b ? a : b);
            if (max - min < 30 || max < 45) continue;
            final key = (r ~/ 32) * 64 + (g ~/ 32) * 8 + b ~/ 32;
            final bin = bins.putIfAbsent(key, () => [0, 0, 0, 0]);
            bin[0]++;
            bin[1] += r;
            bin[2] += g;
            bin[3] += b;
          }
          if (bins.isNotEmpty) {
            final sorted = bins.values.toList()
              ..sort((a, b) => b[0].compareTo(a[0]));
            final best = sorted[0];
            final original = Color.fromARGB(
              255,
              best[1] ~/ best[0],
              best[2] ~/ best[0],
              best[3] ~/ best[0],
            );
            var hsl = HSLColor.fromColor(original).withSaturation(
              HSLColor.fromColor(original).saturation.clamp(0.35, 0.8),
            );
            hsl = hsl.withLightness(hsl.lightness.clamp(0.58, 0.78));
            dominant = hsl.toColor();
            while ((dominant.computeLuminance() + 0.05) /
                        (AppColors.layer.computeLuminance() + 0.05) <
                    4.5 &&
                hsl.lightness < 0.95) {
              hsl = hsl.withLightness((hsl.lightness + 0.02).clamp(0.0, 1.0));
              dominant = hsl.toColor();
            }

            // Extract vibrant tone from second prominent cluster if available
            if (sorted.length > 1) {
              final sec = sorted[1];
              final secColor = Color.fromARGB(
                255,
                sec[1] ~/ sec[0],
                sec[2] ~/ sec[0],
                sec[3] ~/ sec[0],
              );
              final secHsl = HSLColor.fromColor(
                secColor,
              ).withSaturation(0.7).withLightness(0.65);
              vibrant = secHsl.toColor();
            } else {
              vibrant = HSLColor.fromColor(dominant)
                  .withHue((HSLColor.fromColor(dominant).hue + 25) % 360)
                  .toColor();
            }

            // Extract muted ambient tonal color
            final darkHsl = HSLColor.fromColor(
              original,
            ).withSaturation(0.3).withLightness(0.18);
            muted = darkHsl.toColor();
          }
        }
      }
    } catch (_) {
      /* Missing or undecodable artwork uses the fallback. */
    }
    if (mounted && generation == _generation) {
      setState(() {
        _color = dominant;
        _palette = MediaAccentPalette(
          dominant: dominant,
          vibrant: vibrant,
          muted: muted,
        );
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AnimatedTheme(
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 400),
      data: theme.copyWith(
        colorScheme: theme.colorScheme.copyWith(
          primary: _color,
          secondary: _color,
        ),
        sliderTheme: theme.sliderTheme.copyWith(
          activeTrackColor: _color,
          thumbColor: _color,
          overlayColor: _color.withValues(alpha: 0.14),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: theme.filledButtonTheme.style?.copyWith(
            backgroundColor: WidgetStatePropertyAll(_color),
          ),
        ),
        textButtonTheme: TextButtonThemeData(
          style: theme.textButtonTheme.style?.copyWith(
            foregroundColor: WidgetStatePropertyAll(_color),
          ),
        ),
        extensions: [
          MediaAccent(color: _color),
          _palette,
        ],
      ),
      child: widget.child,
    );
  }
}
