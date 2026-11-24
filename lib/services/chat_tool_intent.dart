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
