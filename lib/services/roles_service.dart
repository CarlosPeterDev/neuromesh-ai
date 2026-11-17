import 'dart:convert';

import 'package:get/get.dart';

import 'hive_service.dart';

/// A reusable persona: a name, an emoji and the instructions the model follows
/// when the role is applied to a chat.
class AiRole {
  final String id;
  final String name;
  final String emoji;
  final String prompt;
  final bool builtIn;
  const AiRole(
      {required this.id,
      required this.name,
      required this.emoji,
      required this.prompt,
      this.builtIn = false});

  Map<String, dynamic> toMap() =>
      {'id': id, 'name': name, 'emoji': emoji, 'prompt': prompt};

  static AiRole fromMap(Map m) => AiRole(
      id: '${m['id']}',
      name: '${m['name']}',
      emoji: '${m['emoji'] ?? '🎭'}',
      prompt: '${m['prompt'] ?? ''}');
}

/// The user's custom roles plus a few built-in ones.
class RolesService extends GetxService {
  static const _key = 'custom_roles_v1';

  static const builtIns = <AiRole>[
    AiRole(
        id: 'builtin-coder',
        name: 'Coder',
        emoji: '💻',
        builtIn: true,
        prompt:
            'You are a senior software engineer. Give correct, minimal, working code with a short explanation. Ask about missing requirements instead of guessing.'),
    AiRole(
        id: 'builtin-translator',
        name: 'Translator',
        emoji: '🌍',
        builtIn: true,
        prompt:
            'You are a professional translator. Translate faithfully between Arabic and English (or the language asked), keep the tone, and add short notes only when a phrase has no direct equivalent.'),
    AiRole(
        id: 'builtin-teacher',
        name: 'Teacher',
        emoji: '🎓',
        builtIn: true,
        prompt:
            'You are a patient teacher. Explain step by step with simple examples, check understanding with a short question, and adapt to the learner\'s level.'),
    AiRole(
        id: 'builtin-writer',
        name: 'Writer',
        emoji: '✍️',
        builtIn: true,
        prompt:
            'You are an editor and writer. Improve clarity and flow, keep the author\'s voice, and explain big changes briefly.'),
  ];

  final custom = <AiRole>[].obs;

  HiveService get _hive => Get.find<HiveService>();

  static RolesService ensure() => Get.isRegistered<RolesService>()
      ? Get.find<RolesService>()
      : Get.put(RolesService(), permanent: true);

  List<AiRole> get all => [...custom, ...builtIns];

  @override
  void onInit() {
    super.onInit();
    final raw = _hive.getSetting<String>(_key);
    if (raw != null && raw.isNotEmpty) {
      try {
        final list = jsonDecode(raw) as List;
        custom.assignAll(list.map((e) => AiRole.fromMap(Map.from(e as Map))));
      } catch (_) {}
    }
  }

  Future<void> _save() =>
      _hive.setSetting(_key, jsonEncode(custom.map((r) => r.toMap()).toList()));

  Future<void> upsert(AiRole r) async {
    final i = custom.indexWhere((e) => e.id == r.id);
    if (i >= 0) {
      custom[i] = r;
    } else {
      custom.insert(0, r);
    }
    await _save();
  }

  Future<void> remove(String id) async {
    custom.removeWhere((e) => e.id == id);
    await _save();
  }

  static String newId() => 'role-${DateTime.now().microsecondsSinceEpoch}';
}
