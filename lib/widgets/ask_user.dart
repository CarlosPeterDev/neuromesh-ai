import 'package:flutter/material.dart';
import 'package:get/get.dart';

/// Lets the AI ask the user a question mid-task. Returns the user's answer
/// (a tapped option or typed text), or a note that they skipped it.
Future<String> askUserDialog(String question, List<String> options) async {
  final ctl = TextEditingController();
  final r = await Get.dialog<String>(
    PopScope(
      canPop: false,
      child: AlertDialog(
        title: const Text('The AI has a question'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(question),
              if (options.isNotEmpty) ...[
                const SizedBox(height: 12),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  for (final o in options.take(8))
                    ActionChip(label: Text(o), onPressed: () => Get.back(result: o)),
                ]),
              ],
              const SizedBox(height: 12),
              TextField(
                controller: ctl,
                autofocus: options.isEmpty,
                minLines: 1,
                maxLines: 4,
                decoration: const InputDecoration(hintText: 'Type your answer'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Get.back(result: ''), child: const Text('Skip')),
          TextButton(
              onPressed: () => Get.back(result: ctl.text.trim()),
              child: const Text('Send')),
        ],
      ),
    ),
    barrierDismissible: false,
  );
  final a = (r ?? '').trim();
  return a.isEmpty ? '(The user skipped the question. Make a reasonable assumption and say so.)' : a;
}
