import 'dart:io';

import '../../lib/services/chat_tool_intent.dart';

void main(List<String> args) => stdout.write(switch (args.firstOrNull) {
      'follow-up' => visualFollowUpInstructions,
      'confirm-image' => visualConfirmationInstructions,
      'calculator' => calculatorOptionsInstructions,
      _ => toolIntentInstructions,
    });
