import 'dart:io';

import '../../lib/services/chat_visual_intent.dart';

void main(List<String> args) => stdout.write(
    args.isEmpty ? visualIntentInstructions : visualFollowUpInstructions);
