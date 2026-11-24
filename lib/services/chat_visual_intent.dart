const visualIntentInstructions =
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
