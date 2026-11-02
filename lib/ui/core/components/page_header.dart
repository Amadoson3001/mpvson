import 'package:flutter/material.dart';

import '../app_theme.dart';

/// Title block shared by every full-page screen (Home, Folders, Settings).
///
/// Keeps the title size, left inset and spacing identical across pages, and
/// wraps the trailing actions under the title instead of overflowing when the
/// window is narrow or the text scale is large.
class PageHeader extends StatelessWidget {
  const PageHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.actions = const <Widget>[],
    this.padding,
  });

  final String title;
  final String? subtitle;
  final List<Widget> actions;

  /// Defaults to the page gutter used by library screens.
  final EdgeInsetsGeometry? padding;

  /// Horizontal page gutter for the given content width.
  static double gutterFor(double width) =>
      width < AppLayout.compactBreakpoint ? AppSpace.md : AppSpace.xl;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return LayoutBuilder(
      builder: (context, constraints) {
        final gutter = gutterFor(constraints.maxWidth);
        final titleBlock = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Semantics(
              header: true,
              child: Text(
                title,
                style: palette.pageTitle,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (subtitle != null) ...[
              const SizedBox(height: AppSpace.xxs),
              Text(
                subtitle!,
                style: palette.rowSecondary.copyWith(fontSize: AppType.small),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ],
        );
        return Padding(
          padding:
              padding ??
              EdgeInsets.fromLTRB(gutter, AppSpace.lg, gutter, AppSpace.md),
          child: actions.isEmpty
              ? titleBlock
              : Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: AppSpace.md,
                  runSpacing: AppSpace.sm,
                  children: [
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: (constraints.maxWidth - gutter * 2).clamp(
                          0.0,
                          double.infinity,
                        ),
                      ),
                      child: titleBlock,
                    ),
                    Wrap(
                      spacing: AppSpace.xs,
                      runSpacing: AppSpace.xs,
                      children: actions,
                    ),
                  ],
                ),
        );
      },
    );
  }
}
