import 'package:flutter/material.dart';

/// Desktop spacing and shape values shared by operational screens.
abstract final class AppLayout {
  static const double space4 = 4;
  static const double space8 = 8;
  static const double space12 = 12;
  static const double space16 = 16;
  static const double space20 = 20;
  static const double space24 = 24;
  static const double space32 = 32;
  static const double sectionGap = 20;
  static const double controlGap = 12;

  static const double sidebarWidth = 236;
  static const double collapsedSidebarWidth = 72;
  static const double filterHeight = 36;
  static const double controlHeight = 44;
  static const double searchHeight = 44;
  static const double rowMinHeight = 76;
  static const double metricHeight = 104;
  static const double rowIconSize = 18;
  static const double metricIconSize = 21;
  static const double contentMaxWidth = double.infinity;
  static const EdgeInsets pagePadding =
      EdgeInsets.symmetric(horizontal: space24, vertical: space24);
  static EdgeInsets workspacePadding(double width) => EdgeInsets.symmetric(
      horizontal: width >= 1600
          ? space32
          : width >= 1300
              ? 28
              : space24,
      vertical: space24);
  static const BorderRadius controlRadius =
      BorderRadius.all(Radius.circular(8));
  static const BorderRadius panelRadius = BorderRadius.all(Radius.circular(10));
  static const BorderRadius dialogRadius =
      BorderRadius.all(Radius.circular(14));
}
