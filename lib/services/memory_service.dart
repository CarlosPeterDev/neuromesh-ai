import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/widgets.dart';
import 'package:get/get.dart';

import '../controllers/chat_controller.dart';
import '../utils/memory_text.dart';
import 'chat_tool_service.dart';
import 'hive_service.dart';
import 'inference_service.dart';

/// Keeps the AI's memory of the user fresh by itself: every so often it reads
/// the chat messages written since the last run and asks the loaded model for
/// lasting facts about the user. New facts are merged into the same memory
/// list the agent already injects into every chat ([ChatToolService.memory]),
/// marked as "added automatically" so the user can review and edit them.
class MemoryService extends GetxService with WidgetsBindingObserver {
  static const _kEnabled = 'memory_auto_update';
  static const _kIntervalH = 'memory_interval_hours';
  static const _kLastRun = 'memory_last_run';
  static const _kLastTs = 'memory_last_message_ts';
  static const _kAutoNotes = 'agent_memory_auto_notes';

  /// Characters of recent chat text given to the model per run.
  static const maxTranscript = 6000;

  /// New facts accepted per run.
  static const maxPerRun = 8;

  /// Choices shown in the UI: hours, 0 = manual only.
  static const intervals = <(int, String)>[
    (6, 'Every 6 h'),
    (12, 'Every 12 h'),
    (24, 'Daily'),
    (168, 'Weekly'),
    (0, 'Manual'),
  ];

  final enabled = true.obs;
  final intervalHours = 24.obs;
  final lastRunMs = 0.obs;
  final running = false.obs;
  final status = ''.obs;
  final autoNotes = <String>{}.obs;

  Timer? _timer;

  HiveService get _hive => Get.find<HiveService>();
  ChatToolService get _agent => Get.find<ChatToolService>();

  /// Returns the running service, creating it if main.dart did not.
  static MemoryService ensure() => Get.isRegistered<MemoryService>()
      ? Get.find<MemoryService>()
      : Get.put(MemoryService(), permanent: true);

  @override
  void onInit() {
    super.onInit();
    enabled.value = _hive.getSetting<bool>(_kEnabled) ?? true;
    intervalHours.value = _hive.getSetting<int>(_kIntervalH) ?? 24;
    lastRunMs.value = _hive.getSetting<int>(_kLastRun) ?? 0;
    autoNotes.addAll(
        (_hive.getSetting<List>(_kAutoNotes) ?? const []).map((e) => '$e'));
    if (kIsWeb) return;
    WidgetsBinding.instance.addObserver(this);
    _timer = Timer.periodic(const Duration(minutes: 15), (_) => _checkDue());
    Future.delayed(const Duration(seconds: 25), _checkDue);
  }

  @override
  void onClose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.onClose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _checkDue();
  }

  // ── settings ─────────────────────────────────────────────────────────

  Future<void> setEnabled(bool v) async {
    enabled.value = v;
    await _hive.setSetting(_kEnabled, v);
  }

  Future<void> setIntervalHours(int h) async {
    intervalHours.value = h;
    await _hive.setSetting(_kIntervalH, h);
  }

  bool isAuto(String note) => autoNotes.contains(note);

  /// Call when the user edits or deletes a note so it is no longer "auto".
  Future<void> unmarkAuto(String note) async {
    if (autoNotes.remove(note)) await _saveAuto();
  }

  Future<void> clearAutoMarks() async {
    autoNotes.clear();
    await _saveAuto();
  }

  Future<void> _saveAuto() => _hive.setSetting(_kAutoNotes, autoNotes.toList());

  DateTime? get nextRun {
    if (!enabled.value || intervalHours.value <= 0) return null;
    if (lastRunMs.value == 0) return DateTime.now();
    return DateTime.fromMillisecondsSinceEpoch(lastRunMs.value)
        .add(Duration(hours: intervalHours.value));
  }

  // ── running ──────────────────────────────────────────────────────────

  void _checkDue() {
    if (!enabled.value || intervalHours.value <= 0 || running.value) return;
    final last = DateTime.fromMillisecondsSinceEpoch(lastRunMs.value);
    if (lastRunMs.value != 0 &&
        DateTime.now().difference(last) < Duration(hours: intervalHours.value)) {
      return;
    }
    unawaited(updateNow(silentWhenUnavailable: true));
  }

  /// Reads new chat messages and adds lasting facts to memory. Returns a short
  /// human-readable result (also kept in [status]).
  Future<String> updateNow({bool silentWhenUnavailable = false}) async {
    if (running.value) return status.value;
    final inf = Get.find<InferenceService>();
    String done(String s) {
      status.value = s;
      return s;
    }

    if (!inf.isModelLoaded.value) {
      return silentWhenUnavailable
          ? status.value
          : done('Load a chat model first, then try again.');
    }
    if (inf.isGenerating.value || inf.isLoadingModel.value) {
      return silentWhenUnavailable
          ? status.value
          : done('The model is busy right now. Try again in a moment.');
    }

    // A background run must never get in the way of a chat in progress.
    if (silentWhenUnavailable && Get.isRegistered<ChatController>()) {
      final chat = Get.find<ChatController>();
      if (chat.isLoading.value || chat.isStreaming.value) return status.value;
    }

    running.value = true;
    try {
      final lastTs = _hive.getSetting<int>(_kLastTs) ?? 0;
      final fresh = _recentMessages(lastTs);
      if (fresh.messages.isEmpty) {
        await _markRun(lastTs);
        return done('No new messages since the last update.');
      }
      var transcript = fresh.messages.join('\n');
      if (transcript.length > maxTranscript) {
        transcript = transcript.substring(transcript.length - maxTranscript);
      }
      final known = _agent.memory
          .reversed
          .where((note) => !isMemoryTask(note))
          .take(40)
          .toList()
          .reversed
          .map((n) => '- $n')
          .join('\n');
      var raw = await inf.generate(
        prompt: 'Below is part of a recent conversation between a user and an AI assistant.\n'
            'List lasting facts about the USER that would help in future chats: who they are, '
            'their work, projects, tools, preferences, goals, constraints, languages, habits.\n'
            'Rules: one short line per fact, each starting with "- ". Maximum $maxPerRun lines. '
            'Only facts the user stated or clearly showed. Omit tasks, commands, action items, and requests to do work. '
            'Keep lasting preferences and project context as facts, for example: User builds Flutter apps. '
            'Omit facts already known, passwords, keys, tokens, card or ID numbers. '
            'If there is nothing worth keeping, write only: NONE\n\n'
            'Already known:\n${known.isEmpty ? '(nothing yet)' : known}\n\n'
            'Conversation:\n$transcript',
        systemPrompt: 'You extract short, durable facts about a user for a personal memory list.',
        conversationHistory: const [],
        source: 'memory',
        maxTokens: 320,
        stopSequences: const [],
        onToken: (_) {},
      );
      // Clear what this run left in the engine, but not if the user's own
      // chat has started generating in the meantime.
      final chatBusy = Get.isRegistered<ChatController>() &&
          (Get.find<ChatController>().isLoading.value || Get.find<ChatController>().isStreaming.value);
      if (!chatBusy && !inf.isGenerating.value) {
        try {
          await inf.resetConversation();
        } catch (_) {}
      }
      raw = raw.trim();
      if (raw.startsWith('ERROR')) {
        await _markRun(lastTs); // wait for the next interval instead of retrying every 15 min
        return done('The model could not run: $raw');
      }

      final added = await _merge(parseFacts(raw));
      await _markRun(fresh.newestTs);
      return done(added == 0
          ? 'Checked ${fresh.messages.length} new messages: nothing new to remember.'
          : 'Added $added new ${added == 1 ? 'fact' : 'facts'} from ${fresh.messages.length} new messages.');
    } catch (e) {
      return done('Memory update failed: $e');
    } finally {
      running.value = false;
    }
  }

  Future<void> _markRun(int newestTs) async {
    lastRunMs.value = DateTime.now().millisecondsSinceEpoch;
    await _hive.setSetting(_kLastRun, lastRunMs.value);
    if (newestTs > 0) await _hive.setSetting(_kLastTs, newestTs);
  }

  ({List<String> messages, int newestTs}) _recentMessages(int afterTs) {
    final rows = <({int ts, String line})>[];
    for (final v in _hive.messagesBox.values) {
      if (v is! Map) continue;
      final role = '${v['role']}';
      // Only the user's own words: assistant text may quote web pages, and a
      // hostile page must not be able to write "facts" into memory.
      if (role != 'user') continue;
      var content = '${v['content'] ?? ''}'.trim();
      if (content.isEmpty ||
          content.startsWith('[IMAGE_BASE64]') ||
          v['isCommand'] == true) {
        continue;
      }
      final ts = DateTime.tryParse('${v['timestamp']}')?.millisecondsSinceEpoch ?? 0;
      if (ts <= afterTs) continue;
      // Tool traces and thinking blocks are noise for this purpose.
      content = content
          .replaceAll(RegExp(r'<think>[\s\S]*?</think>'), '')
          .replaceAll(RegExp(r'^> .*$', multiLine: true), '')
          .trim();
      if (content.isEmpty) continue;
      if (role == 'assistant' && content.length > 240) {
        content = '${content.substring(0, 240)}…';
      }
      if (role == 'user' && content.length > 1200) {
        content = content.substring(0, 1200);
      }
      rows.add((ts: ts, line: '${role == 'user' ? 'User' : 'Assistant'}: $content'));
    }
    rows.sort((a, b) => a.ts.compareTo(b.ts));
    return (
      messages: [for (final r in rows) r.line],
      newestTs: rows.isEmpty ? 0 : rows.last.ts,
    );
  }

  static final _secret = RegExp(
      r'(password|passcode|passwd|api[ _-]?key|secret|token|otp|cvv|iban|ssn|private key|credit card|card number|bearer)',
      caseSensitive: false);
  static final _longId = RegExp(r'[A-Za-z0-9_\-]{28,}|\d{9,}');

  /// Turns the model's reply into clean, safe one-line facts.
  static List<String> parseFacts(String raw) {
    final text = raw.replaceAll(RegExp(r'<think>[\s\S]*?</think>'), '');
    final out = <String>[];
    for (var line in text.split('\n')) {
      line = line.trim();
      if (line.isEmpty) continue;
      final m = RegExp(r'^(?:[-*•–]|\d+[.)])\s+(.*)$').firstMatch(line);
      if (m == null) continue;
      var fact = m.group(1)!.replaceAll(RegExp(r'\s+'), ' ').trim();
      fact = fact.replaceAll(RegExp(r'^\*+|\*+$'), '').trim();
      final low = fact.toLowerCase();
      if (fact.length < 6 || fact.length > 200) continue;
      if (low == 'none' || low.startsWith('none ') || low.startsWith('nothing')) continue;
      if (_secret.hasMatch(fact) || _longId.hasMatch(fact) || isMemoryTask(fact)) continue;
      out.add(fact);
      if (out.length >= maxPerRun) break;
    }
    return out;
  }

  static Set<String> _words(String s) => s
      .toLowerCase()
      .replaceAll(RegExp(r'[^\p{L}\p{N}\s]', unicode: true), ' ')
      .split(RegExp(r'\s+'))
      .where((w) => w.length > 2)
      .toSet();

  /// True when [a] and [b] say nearly the same thing.
  static bool similar(String a, String b) {
    final la = a.toLowerCase().trim();
    final lb = b.toLowerCase().trim();
    if (la == lb || la.contains(lb) || lb.contains(la)) return true;
    final wa = _words(a);
    final wb = _words(b);
    if (wa.isEmpty || wb.isEmpty) return false;
    final inter = wa.intersection(wb).length;
    final union = wa.union(wb).length;
    return inter / union >= 0.7;
  }

  Future<int> _merge(List<String> facts) async {
    var added = 0;
    for (final f in facts) {
      if (_agent.memory.any((n) => similar(n, f))) continue;
      // Keep room: drop the oldest automatic note before touching the user's own.
      if (_agent.memory.length >= ChatToolService.maxMemory) {
        final old = _agent.memory.firstWhereOrNull(autoNotes.contains);
        if (old == null) break;
        await _agent.removeNote(old);
        autoNotes.remove(old);
      }
      await _agent.addNote(f);
      // addNote trims to 300 chars; the saved text is what the list holds.
      final saved = _agent.memory.isNotEmpty ? _agent.memory.last : f;
      autoNotes.add(saved);
      added++;
    }
    await _saveAuto();
    return added;
  }
}
