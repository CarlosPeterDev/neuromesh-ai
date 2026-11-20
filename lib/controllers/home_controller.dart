import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../views/onboarding.dart';
import '../services/hive_service.dart';
import '../services/inference_service.dart';
import 'model_controller.dart';

class HomeController extends GetxController {
  final currentTab = 0.obs;
  final modelScroll = ScrollController();
  final _tabHistory = <int>[];

  void modelsToTop() {
    if (modelScroll.hasClients) {
      modelScroll.jumpTo(modelScroll.position.minScrollExtent);
    }
  }

  bool goBack() {
    if (scaffoldKey.currentState?.isDrawerOpen == true) {
      closeSidebar();
      return true;
    }
    if (_tabHistory.isEmpty) return false;
    currentTab.value = _tabHistory.removeLast();
    if (currentTab.value == 1) modelsToTop();
    return true;
  }

  @override
  void onClose() {
    modelScroll.dispose();
    super.onClose();
  }

  /// Root scaffold key — the chat sidebar hangs off the root so it slides
  /// over the bottom navigation bar instead of under it.
  final scaffoldKey = GlobalKey<ScaffoldState>();

  @override
  void onReady() {
    super.onReady();
    // Optional: load the last used chat model when the app starts.
    Future.delayed(const Duration(seconds: 1), () async {
      try {
        final hive = Get.find<HiveService>();
        final mc = Get.find<ModelController>();
        final inf = Get.find<InferenceService>();
        if (hive.getSetting<bool>('auto_load_last', defaultValue: false) ==
                true &&
            mc.canLoadLastModel &&
            !inf.isModelLoaded.value &&
            !inf.isLoadingModel.value) {
          await mc.reloadLastModel();
        }
      } catch (_) {}
    });
    Future.delayed(const Duration(seconds: 3), () {
      final ctx = Get.context;
      if (ctx == null) return;
      try {
        runFirstRunFlow(ctx);
      } catch (_) {}
    });
  }

  void changeTab(int index) {
    if (currentTab.value == index) {
      if (index == 1) modelsToTop();
      return;
    }
    _tabHistory.remove(index);
    _tabHistory.add(currentTab.value);
    currentTab.value = index;
  }

  void openSidebar() => scaffoldKey.currentState?.openDrawer();

  void closeSidebar() => scaffoldKey.currentState?.closeDrawer();
}
