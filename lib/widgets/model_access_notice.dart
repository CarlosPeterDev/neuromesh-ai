import 'package:flutter/material.dart';

/// Model weights grant no Android permissions; access belongs to app tools.
class ModelAccessNotice extends StatelessWidget {
  const ModelAccessNotice({super.key, required this.onReview});
  final VoidCallback onReview;
  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('You control model access',
                style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            const Text(
                'Downloading a model grants no microphone, camera or file access. '
                'Voice and camera features ask for Android permission when used. '
                'File tools use the folder you select. Online tools send their inputs '
                'to their provider; tool approvals control sensitive actions.'),
            TextButton.icon(
                onPressed: onReview,
                icon: const Icon(Icons.shield_outlined),
                label: const Text('Review tools & permissions')),
          ]),
        ),
      );
}
