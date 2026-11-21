/// Filenames remain readable in labels but must be escaped in Markdown URIs.
String outputFileUri(String name) =>
    'nmfile:${Uri.encodeComponent(name).replaceAll('(', '%28').replaceAll(')', '%29')}';

String outputFileName(String encoded) {
  try {
    return Uri.decodeComponent(encoded);
  } on FormatException {
    return encoded;
  }
}

String outputLabel(String name) =>
    name.replaceAllMapped(RegExp(r'[\\\[\]]'), (m) => '\\${m[0]}');

/// Also repairs older saved replies whose generated filenames contained spaces.
String normalizeOutputLinks(String text) => text.replaceAllMapped(
    RegExp(r'\(nmfile:([^\r\n)]+)\)'),
    (m) => '(${outputFileUri(outputFileName(m[1]!))})');

Set<String> outputFileNames(String text, {bool imagesOnly = false}) =>
    RegExp(imagesOnly
            ? r'!\[[^\]\r\n]*\]\(nmfile:([^\r\n)]+)\)'
            : r'\(nmfile:([^\r\n)]+)\)')
        .allMatches(text)
        .map((m) => outputFileName(m[1]!))
        .toSet();
