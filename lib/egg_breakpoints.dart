import 'package:flutter/widgets.dart';

/// Shared layout breakpoints for phone / tablet / desktop.
abstract final class EggBreakpoints {
  /// Phone / narrow web column.
  static const double compact = 600;

  /// Tablet / medium shell (sidebar appears at [expanded]).
  static const double medium = 840;

  /// Comfortable multi-column content.
  static const double wide = 1040;

  static double widthOf(BuildContext context) =>
      MediaQuery.sizeOf(context).width;

  static bool isCompact(BuildContext context) => widthOf(context) < compact;

  static bool isMedium(BuildContext context) {
    final double w = widthOf(context);
    return w >= compact && w < medium;
  }

  static bool isExpanded(BuildContext context) => widthOf(context) >= medium;

  static bool isWide(BuildContext context) => widthOf(context) >= wide;
}
