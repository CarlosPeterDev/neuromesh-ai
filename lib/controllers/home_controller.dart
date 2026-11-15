import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../views/onboarding.dart';
import '../services/hive_service.dart';
import '../services/inference_service.dart';
import 'model_controller.dart';

class HomeController extends GetxController {
  final currentTab = 0.obs;

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
        if (hive.getSetting<bool>('auto_load_last', defaultValue: false) == true &&
            mc.canLoadLastModel &&
            !inf.isModelLoaded.value &&
            !inf.isLoadingModel.value) {
          await mc.loadModel(mc.lastLoadedModelName);
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
    currentTab.value = index;
  }

  void openSidebar() => scaffoldKey.currentState?.openDrawer();

  void closeSidebar() => scaffoldKey.currentState?.closeDrawer();
}
