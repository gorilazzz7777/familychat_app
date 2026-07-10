import 'package:flutter/material.dart';

/// TabBar с подчёркиванием на всю ширину слота таба (а не только под текстом).
abstract final class FamilyTabBar {
  static TabBar build({
    required List<Widget> tabs,
    TabController? controller,
    bool isScrollable = false,
    TabAlignment? tabAlignment,
    Color? dividerColor,
    TextStyle? labelStyle,
    TextStyle? unselectedLabelStyle,
    Color? labelColor,
    Color? unselectedLabelColor,
    Decoration? indicator,
    double? indicatorWeight,
    EdgeInsetsGeometry? labelPadding,
    EdgeInsetsGeometry? padding,
  }) {
    return TabBar(
      controller: controller,
      tabs: tabs,
      isScrollable: isScrollable,
      tabAlignment: tabAlignment ??
          (isScrollable ? TabAlignment.start : TabAlignment.fill),
      indicatorSize: TabBarIndicatorSize.tab,
      dividerColor: dividerColor,
      labelStyle: labelStyle,
      unselectedLabelStyle: unselectedLabelStyle,
      labelColor: labelColor,
      unselectedLabelColor: unselectedLabelColor,
      indicator: indicator,
      indicatorWeight: indicatorWeight ?? 3,
      labelPadding: labelPadding,
      padding: padding,
    );
  }
}
