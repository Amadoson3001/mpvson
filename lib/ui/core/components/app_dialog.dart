import 'package:flutter/material.dart';

import '../app_theme.dart';

/// Standard modal dialog shell providing consistent background, border radius,
/// elevation, shadow, and token-based padding across mpvson.
class AppDialog extends StatelessWidget {
  const AppDialog({
    super.key,
    this.icon,
    this.title,
    this.content,
    this.actions,
    this.child,
    this.maxWidth = 480.0,
    this.maxHeight,
    this.constraints,
    this.scrollable = false,
    this.insetPadding = const EdgeInsets.symmetric(
      horizontal: AppSpace.lg,
      vertical: AppSpace.xl,
    ),
    this.padding,
    this.titlePadding,
    this.contentPadding,
    this.actionsPadding,
    this.actionsAxis = Axis.horizontal,
    this.actionsSpacing = AppSpace.xs,
    this.backgroundColor,
    this.elevation = 12.0,
    this.shadowColor,
    this.clipBehavior = Clip.antiAlias,
    this.borderRadius,
    this.borderColor,
  }) : assert(
         child != null || content != null || title != null,
         'Either child or content/title must be provided',
       );

  /// Optional icon placed above the title.
  final Widget? icon;

  /// The title widget of the dialog (typically [Text]).
  final Widget? title;

  /// The primary content of the dialog.
  final Widget? content;

  /// Actions placed at the bottom of the dialog (e.g. Cancel / Confirm buttons).
  final List<Widget>? actions;

  /// Custom layout widget for non-standard dialog bodies. If provided,
  /// [title], [content], and [actions] are ignored.
  final Widget? child;

  /// Maximum width of the dialog. Defaults to 480.0.
  final double? maxWidth;

  /// Maximum height of the dialog. Defaults to screen height minus insets.
  final double? maxHeight;

  /// Explicit constraints override. If provided, [maxWidth] and [maxHeight] are ignored.
  final BoxConstraints? constraints;

  /// Whether the [content] should be automatically wrapped in a [SingleChildScrollView].
  final bool scrollable;

  /// Padding around the outside of the dialog relative to the screen.
  final EdgeInsets insetPadding;

  /// Content padding applied when [child] is provided, or as fallback for [contentPadding].
  final EdgeInsets? padding;

  /// Padding around the title. Defaults to [AppSpace.lg] left/top/right and [AppSpace.xs] bottom.
  final EdgeInsets? titlePadding;

  /// Padding around the content.
  final EdgeInsets? contentPadding;

  /// Padding around the actions row/column. Defaults to [AppSpace.lg] horizontal and bottom.
  final EdgeInsets? actionsPadding;

  /// Direction of the action buttons. Defaults to [Axis.horizontal].
  final Axis actionsAxis;

  /// Spacing between action buttons. Defaults to [AppSpace.xs] (8.0).
  final double actionsSpacing;

  /// Background color of the dialog. Defaults to `context.palette.surface`.
  final Color? backgroundColor;

  /// Elevation of the dialog container. Defaults to 12.0.
  final double elevation;

  /// Drop shadow color. Defaults to 35% black.
  final Color? shadowColor;

  /// Clip behavior. Defaults to [Clip.antiAlias].
  final Clip clipBehavior;

  /// Border radius override. Defaults to [AppRadii.artwork] (10.0).
  final double? borderRadius;

  /// Border side color override. Defaults to `context.palette.border`.
  final Color? borderColor;

  /// Displays an [AppDialog] with the standard barrier configuration.
  static Future<T?> show<T>({
    required BuildContext context,
    required WidgetBuilder builder,
    bool barrierDismissible = true,
    Color? barrierColor = Colors.black54,
    bool useSafeArea = true,
    RouteSettings? routeSettings,
  }) {
    return showDialog<T>(
      context: context,
      barrierDismissible: barrierDismissible,
      barrierColor: barrierColor,
      useSafeArea: useSafeArea,
      routeSettings: routeSettings,
      builder: builder,
    );
  }

  @override
  Widget build(BuildContext context) {
    final effectiveRadius = borderRadius ?? AppRadii.artwork;
    final effectiveBorderColor = borderColor ?? context.palette.border;
    final dialogShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(effectiveRadius),
      side: BorderSide(color: effectiveBorderColor),
    );

    final screenHeight = MediaQuery.sizeOf(context).height;
    final effectiveConstraints =
        constraints ??
        BoxConstraints(
          maxWidth: maxWidth ?? double.infinity,
          maxHeight:
              maxHeight ?? (screenHeight - 80.0).clamp(100.0, double.infinity),
        );

    final Widget body;
    if (child != null) {
      body = padding != null
          ? Padding(padding: padding!, child: child!)
          : child!;
    } else {
      final hasActions = actions != null && actions!.isNotEmpty;
      final effectiveTitlePadding =
          titlePadding ??
          EdgeInsets.fromLTRB(
            AppSpace.lg,
            icon != null ? AppSpace.xs : AppSpace.lg,
            AppSpace.lg,
            AppSpace.xs,
          );
      final effectiveContentPadding =
          contentPadding ??
          (padding ??
              EdgeInsets.fromLTRB(
                AppSpace.lg,
                title != null ? AppSpace.xs : AppSpace.lg,
                AppSpace.lg,
                hasActions ? AppSpace.md : AppSpace.lg,
              ));
      final effectiveActionsPadding =
          actionsPadding ??
          const EdgeInsets.fromLTRB(
            AppSpace.lg,
            AppSpace.xs,
            AppSpace.lg,
            AppSpace.lg,
          );

      body = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (icon != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpace.lg,
                AppSpace.lg,
                AppSpace.lg,
                AppSpace.xs,
              ),
              child: Align(
                alignment: Alignment.centerLeft,
                child: IconTheme(
                  data: IconThemeData(color: context.palette.accent, size: 24),
                  child: icon!,
                ),
              ),
            ),
          if (title != null)
            Padding(
              padding: effectiveTitlePadding,
              child: DefaultTextStyle(
                style: context.palette.albumTitle,
                child: title!,
              ),
            ),
          if (content != null)
            Flexible(
              child: scrollable
                  ? SingleChildScrollView(
                      padding: effectiveContentPadding,
                      child: content!,
                    )
                  : Padding(padding: effectiveContentPadding, child: content!),
            ),
          if (hasActions) _buildActions(effectiveActionsPadding),
        ],
      );
    }

    return Dialog(
      backgroundColor: backgroundColor ?? context.palette.surface,
      surfaceTintColor: Colors.transparent,
      elevation: elevation,
      shadowColor: shadowColor ?? Colors.black.withValues(alpha: 0.35),
      clipBehavior: clipBehavior,
      shape: dialogShape,
      insetPadding: insetPadding,
      child: ConstrainedBox(constraints: effectiveConstraints, child: body),
    );
  }

  Widget _buildActions(EdgeInsets effectiveActionsPadding) {
    return Padding(
      padding: effectiveActionsPadding,
      child: actionsAxis == Axis.horizontal
          ? OverflowBar(
              alignment: MainAxisAlignment.end,
              overflowAlignment: OverflowBarAlignment.end,
              spacing: actionsSpacing,
              overflowSpacing: actionsSpacing,
              children: actions!,
            )
          : Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < actions!.length; i++) ...[
                  if (i > 0) SizedBox(height: actionsSpacing),
                  actions![i],
                ],
              ],
            ),
    );
  }
}
