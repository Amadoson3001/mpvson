import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import '../../../app.dart' show AppPreferencesScope;
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
    this.enabled,
  });
  final PlayerController controller;
  final Widget child;
  final MediaEntry? entryOverride;
  final bool? enabled;
  /// Clamps extracted artwork color to enforce saturation >= 0.65 and balanced lightness
  /// (0.45 - 0.55 in light mode, 0.60 - 0.70 in dark mode) so artwork accents remain
  /// vibrant and high-contrast across all surfaces.
  static Color clampAccentForVibrancy(Color color, Brightness brightness) {
    if (color == AppColors.lamp) return color;
    final hsl = HSLColor.fromColor(color);
    final clampedSat = hsl.saturation.clamp(0.65, 1.0);
    final clampedLight = brightness == Brightness.light
        ? hsl.lightness.clamp(0.45, 0.55)
        : hsl.lightness.clamp(0.60, 0.70);
    return hsl.withSaturation(clampedSat).withLightness(clampedLight).toColor();
  }

  @override
  State<MediaAccentScope> createState() => _MediaAccentScopeState();
}

class _MediaAccentScopeState extends State<MediaAccentScope> {
  static final Map<String, (Color, MediaAccentPalette)> _paletteCache = {};
  static const int _maxPaletteCache = 64;

  String? _path;
  Color? _color;
  MediaAccentPalette? _palette;
  int _generation = 0;
  bool _dynamicArtworkEnabled = true;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
  }

  @override
  void didUpdateWidget(MediaAccentScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    var needsRefresh = false;
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_changed);
      widget.controller.addListener(_changed);
      needsRefresh = true;
    }
    if (oldWidget.entryOverride?.path != widget.entryOverride?.path ||
        oldWidget.enabled != widget.enabled) {
      needsRefresh = true;
    }
    if (needsRefresh) {
      _path = null;
      _changed();
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    _generation++;
    super.dispose();
  }

  bool get _isDynamicEnabled => widget.enabled ?? _dynamicArtworkEnabled;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final enabled = widget.enabled ??
        (AppPreferencesScope.of(context)?.dynamicArtworkColor ?? true);
    _dynamicArtworkEnabled = enabled;
    if (!_isDynamicEnabled) {
      _path = null;
      _generation++;
      if ((_color != null || _palette != null) && mounted) {
        setState(() {
          _color = null;
          _palette = null;
        });
      }
    } else {
      _changed();
    }
  }

  void _changed() {
    if (!_isDynamicEnabled) {
      _path = null;
      _generation++;
      if ((_color != null || _palette != null) && mounted) {
        setState(() {
          _color = null;
          _palette = null;
        });
      }
      return;
    }
    final entry = widget.entryOverride ?? widget.controller.current;
    if (entry?.path == _path) return;
    _path = entry?.path;
    final generation = ++_generation;
    if (entry == null) {
      if (mounted && (_color != null || _palette != null)) {
        setState(() {
          _color = null;
          _palette = null;
        });
      }
      return;
    }
    _extract(entry, generation);
  }

  Future<void> _extract(MediaEntry entry, int generation) async {
    if (!_isDynamicEnabled) return;
    final cached = _paletteCache[entry.path];
    if (cached != null) {
      if (mounted && generation == _generation) {
        setState(() {
          _color = cached.$1;
          _palette = cached.$2;
        });
      }
      return;
    }

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
            final hslOrig = HSLColor.fromColor(original);
            final clampedSat = hslOrig.saturation.clamp(0.65, 1.0);
            final clampedLight = hslOrig.lightness.clamp(0.48, 0.68);
            dominant = hslOrig.withSaturation(clampedSat).withLightness(clampedLight).toColor();

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
              ).withSaturation(0.75).withLightness(0.62);
              vibrant = secHsl.toColor();
            } else {
              vibrant = HSLColor.fromColor(dominant)
                  .withHue((HSLColor.fromColor(dominant).hue + 25) % 360)
                  .withSaturation(0.75)
                  .toColor();
            }

            // Extract muted ambient tonal color
            final darkHsl = HSLColor.fromColor(
              original,
            ).withSaturation(0.25).withLightness(0.20);
            muted = darkHsl.toColor();
          }
        }
      }
    } catch (_) {
      /* Missing or undecodable artwork uses the fallback. */
    }
    final extractedPalette = MediaAccentPalette(
      dominant: dominant,
      vibrant: vibrant,
      muted: muted,
    );
    if (_paletteCache.length >= _maxPaletteCache) {
      _paletteCache.remove(_paletteCache.keys.first);
    }
    _paletteCache[entry.path] = (dominant, extractedPalette);
    if (mounted && generation == _generation && _isDynamicEnabled) {
      setState(() {
        _color = dominant;
        _palette = extractedPalette;
      });
    }
  }


  @override
  Widget build(BuildContext context) {
    if (!_isDynamicEnabled || _color == null) {
      return widget.child;
    }

    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final color = MediaAccentScope.clampAccentForVibrancy(_color!, theme.brightness);
    final onAccent = isDark ? const Color(0xFF09090B) : Colors.white;
    final palette = _palette != null
        ? MediaAccentPalette(
            dominant: color,
            vibrant: MediaAccentScope.clampAccentForVibrancy(_palette!.vibrant, theme.brightness),
            muted: _palette!.muted,
          )
        : MediaAccentPalette(dominant: color);

    return AnimatedTheme(
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 400),
      data: theme.copyWith(
        colorScheme: theme.colorScheme.copyWith(
          primary: color,
          onPrimary: onAccent,
          secondary: color,
          onSecondary: onAccent,
        ),
        switchTheme: SwitchThemeData(
          thumbColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected)
                ? onAccent
                : theme.colorScheme.onSurfaceVariant,
          ),
          trackColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected)
                ? color
                : theme.colorScheme.surfaceContainer,
          ),
          trackOutlineColor: WidgetStatePropertyAll(
            theme.colorScheme.outlineVariant,
          ),
        ),
        sliderTheme: theme.sliderTheme.copyWith(
          activeTrackColor: color,
          thumbColor: color,
          overlayColor: color.withValues(alpha: 0.14),
        ),
        progressIndicatorTheme: theme.progressIndicatorTheme.copyWith(
          color: color,
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: theme.filledButtonTheme.style?.copyWith(
            backgroundColor: WidgetStatePropertyAll(color),
            foregroundColor: WidgetStatePropertyAll(onAccent),
          ),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: theme.elevatedButtonTheme.style?.copyWith(
            backgroundColor: WidgetStatePropertyAll(color),
            foregroundColor: WidgetStatePropertyAll(onAccent),
          ),
        ),
        textButtonTheme: TextButtonThemeData(
          style: theme.textButtonTheme.style?.copyWith(
            foregroundColor: WidgetStatePropertyAll(color),
          ),
        ),
        iconButtonTheme: IconButtonThemeData(
          style: theme.iconButtonTheme.style?.copyWith(
            foregroundColor: WidgetStateProperty.resolveWith(
              (states) => states.contains(WidgetState.disabled)
                  ? theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.4)
                  : states.contains(WidgetState.selected)
                  ? color
                  : theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        badgeTheme: theme.badgeTheme.copyWith(
          textColor: color,
        ),
        segmentedButtonTheme: SegmentedButtonThemeData(
          style: ButtonStyle(
            backgroundColor: WidgetStateProperty.resolveWith((states) {
              return states.contains(WidgetState.selected)
                  ? color
                  : theme.colorScheme.surfaceContainer;
            }),
            foregroundColor: WidgetStateProperty.resolveWith((states) {
              return states.contains(WidgetState.selected)
                  ? onAccent
                  : theme.colorScheme.onSurface;
            }),
          ),
        ),
        extensions: [
          MediaAccent(color: color),
          palette,
        ],
      ),
      child: widget.child,
    );
  }
}
