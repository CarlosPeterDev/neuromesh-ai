import 'dart:convert';

const toolCompletionSource = 'chat-tool-completion';

const toolIntentInstructions =
    'Choose by meaning: calc for a numeric answer to arithmetic; artwork for '
    'making a new picture; text for explanations, code, writing, or chat. Reply with the label only.';

const calculatorOptionsInstructions =
    'Extract the stated decimal precision. Output digits or none. Examples: '
    '"Round to 4 decimal places" → 4. "What is the result?" → none. '
    '"Round to 12 decimal places" → 12.';

const visualConfirmationInstructions =
    'You classify what deliverable another person wants. The user message '
    'is the sample to classify. Answer with one word: artwork or text.\n'
    'artwork = they want you to produce a new visual artifact for them.\n'
    'text = they want a description, explanation, written material, or an '
    'ordinary chat reply. For edits or multiple separate deliverables, choose text.\n'
    'Classify the intent by meaning, including requests in other languages.';

const visualFollowUpInstructions =
    'Classify what the user wants delivered. Answer with one word: artwork, mixed, or text.\n'
    'artwork: one new visual artifact as the complete deliverable.\n'
    'mixed: a new visual artifact PLUS an independent requested deliverable like research or a separate written answer.\n'
    'text: everything else, including discussion, describing something, writing a prompt, and editing an existing image.\n'
    'Examples: a portrait and separate market research = mixed. A portrait with mountains behind it = artwork.\n'
    'Classify meaning in any language.';

/// Few-shot completion on GGUF. The examples teach categories, and only a
/// complete, allowlisted label is accepted. The user prompt is a quoted sample.
String toolRoutingPrompt(String request) => [
      for (final (input, route) in const [
        ('What is 14 plus 8?', 'math'),
        ('A watercolor of Paris please', 'image'),
        ('Give me a recording of someone saying welcome', 'audio'),
        ('Who won yesterday’s match?', 'search'),
        ('Find reviews of affordable microphones', 'search'),
        ('Which language model is currently best at reasoning?', 'search'),
        ('Save these notes in a .txt file', 'file'),
        ('Good morning', 'chat'),
        ('What is a code completion model?', 'chat'),
        ('Write a prompt for an artist', 'chat'),
        ('أريد تسجيلا بصوت يقول مرحبا', 'audio'),
        ('Show how to write a loop in Python.', 'chat'),
        ('Transcribe the attached recording', 'transcribe'),
        ('What is the most capable chatbot for research?', 'search'),
      ])
        '${_quotedSample(input)} -> $route',
      '${_quotedSample(request)} ->',
    ].join('\n');

String _quotedSample(String text) =>
    jsonEncode(text).replaceAll('<', r'\u003c');

String speechPayloadPrompt(String request) => [
      for (final (input, text, voice) in const [
        (
          'Make an audio recording of a male voice saying “Hello, Alex!”',
          'Hello, Alex!',
          'male'
        ),
        ('Read “It is time to go” aloud.', 'It is time to go', ''),
        ('A woman saying good morning', 'good morning', 'female'),
        ('Create a recording', '', ''),
        ('سجل صوت يقول أهلا بك', 'أهلا بك', ''),
        ('A recording of a boy saying welcome', 'welcome', 'male'),
      ])
        '${_quotedSample(input)} -> [${_quotedSample(text)}, ${_quotedSample(voice)}]',
      '${_quotedSample(request)} ->',
    ].join('\n');

String precisionPayloadPrompt(String request) => [
      for (final (input, digits) in const [
        ('Round to 2 decimal places', '2'),
        ('Give 5 decimal places. Show your work.', '5'),
        ('What is the result?', 'none'),
        ('Round to 9 decimal places and explain.', '9'),
      ])
        '${_quotedSample(input)} | precision = $digits',
      '${_quotedSample(request)} | precision =',
    ].join('\n');

Map<String, dynamic>? speechArguments(String raw, String request) {
  final Object? result;
  try {
    result = jsonDecode(raw);
  } on FormatException {
    return null;
  }
  if (result is! List ||
      result.length != 2 ||
      result[0] is! String ||
      result[1] is! String) return null;
  final text = (result[0] as String).trim();
  final voice = result[1] as String;
  if (text.isEmpty || !request.toLowerCase().contains(text.toLowerCase())) {
    return null;
  }
  return {
    'text': text,
    if (const {'male', 'female'}.contains(voice)) 'voice': voice
  };
}

/// Decide if the current message asks to repeat the last failed image action.
/// Called only with a failed image on the immediately preceding turn.
String imageRetryPrompt(String request) {
  const failedImage = 'The requested image was not created.';
  return [
    for (final (status, input, route) in const [
      (failedImage, 'Please make another attempt.', 'retry'),
      (failedImage, 'What is the weather tomorrow?', 'new'),
      (failedImage, 'Give it one more shot', 'retry'),
      (failedImage, 'Create a different picture of a red balloon', 'new'),
      ('فشل إنشاء الصورة', 'حاول مرة أخرى', 'retry'),
      (failedImage, 'Thanks', 'new'),
    ])
      '${_quotedSample(status)} + ${_quotedSample(input)} -> $route',
    '${_quotedSample(failedImage)} + ${_quotedSample(request)} ->',
  ].join('\n');
}
