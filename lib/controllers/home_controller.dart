import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../views/quick_start.dart';

class HomeController extends GetxController {
  final currentTab = 0.obs;

  /// Root scaffold key — the chat sidebar hangs off the root so it slides
  /// over the bottom navigation bar instead of under it.
  final scaffoldKey = GlobalKey<ScaffoldState>();

  @override
  void onReady() {
    super.onReady();
    Future.delayed(const Duration(seconds: 3), () {
      final ctx = Get.context;
      if (ctx == null) return;
      try {
        maybeShowQuickStart(ctx);
      } catch (_) {}
    });
  }

  void changeTab(int index) {
    currentTab.value = index;
  }

  void openSidebar() => scaffoldKey.currentState?.openDrawer();

  void closeSidebar() => scaffoldKey.currentState?.closeDrawer();
}
