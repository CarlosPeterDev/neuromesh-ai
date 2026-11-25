import 'dart:convert';
import 'dart:io';

import '../../lib/services/chat_tool_intent.dart';

void main() {
  for (final (request, route) in const [
    ('Hi', 'chat'),
    ('Explain how a flying car would work.', 'chat'),
    ('Show how to write 5 + 2 in Python.', 'chat'),
    ('Create image of a flying car', 'image'),
    ('ارسم سيارة تطير فوق القاهرة ليلاً', 'image'),
    ('Who won the latest Champions League final?', 'search'),
    ('OK search for the best Ai model for coding', 'search'),
    ('What is the strongest AI in coding', 'search'),
    ('What is a coding model?', 'chat'),
    ('من فاز بكأس العالم الأخيرة؟', 'search'),
    ('Save this as a downloadable .txt: The blue sky.', 'file'),
    (
      'Make an audio recording of a male voice saying “Hello, Carlos!”',
      'audio'
    ),
    ('سجل لي صوت يقول أهلا كارلوس', 'audio'),
    ('Transcribe this audio file, please', 'transcribe'),
    (
      'Calculate the exact numerical value of ((84729 × 93617) + '
          'sqrt(987654321)) / (137.29^2 + 17.83), rounded to 8 decimal places. '
          'Provide the final answer and intermediate calculations.',
      'math'
    ),
  ]) {
    _write(route, 5, toolRoutingPrompt(request));
  }
  _write('retry', 5, imageRetryPrompt('Try again'));
  _write('retry', 5, imageRetryPrompt('جرب مرة ثانية'));
  _write('new', 5, imageRetryPrompt('Who won last night’s match?'));
  _write(
      '8',
      4,
      precisionPayloadPrompt('Calculate the exact numerical value of , rounded '
          'to 8 decimal places. Provide the final answer and intermediate calculations.'));
  _write(
      '["Hello, Carlos!", "male"]',
      16,
      speechPayloadPrompt(
          'Make an audio recording of a male voice saying “Hello, Carlos!”'));
}

void _write(String expected, int limit, String prompt) =>
    stdout.writeln('$expected\t$limit\t${base64Encode(utf8.encode(prompt))}');
