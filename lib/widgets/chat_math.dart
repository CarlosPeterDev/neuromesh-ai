import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:markdown/markdown.dart' as md;

const mathInlineTag = 'nm-math-inline';
const mathDisplayTag = 'nm-math-display';

List<md.InlineSyntax> chatMathSyntax() => [
      _MathSyntax(r'\\\(([^\n]+?)\\\)', mathInlineTag, 92),
      _MathSyntax(r'\$(?![\s$])((?:\\.|[^$\n\\])+?)(?<!\s)\$(?![$\d])',
          mathInlineTag, 36),
    ];

class _MathSyntax extends md.InlineSyntax {
  final String tag;

  _MathSyntax(String pattern, this.tag, int character)
      : super(pattern, startCharacter: character);

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    parser.addNode((md.Element.empty(tag)..attributes['tex'] = match[1]!));
    return true;
  }
}

class ChatMathBlock extends md.BlockSyntax {
  const ChatMathBlock();

  @override
  RegExp get pattern => RegExp(r'^ {0,3}(\$\$|\\\[)');

  @override
  bool canParse(md.BlockParser parser) {
    final line = parser.current.content;
    final opening = pattern.firstMatch(line);
    if (opening == null) return false;
    final end = opening[1] == r'$$' ? r'$$' : r'\]';
    if (line.substring(opening.end).trimRight().endsWith(end)) return true;
    for (var offset = 1; offset <= 80; offset++) {
      final next = parser.peek(offset)?.content;
      if (next == null || next.startsWith('```')) break;
      if (next.trimRight().endsWith(end)) return true;
    }
    return false;
  }

  @override
  md.Node parse(md.BlockParser parser) {
    final first = parser.current.content;
    final opening = pattern.firstMatch(first)!;
    final end = opening[1] == r'$$' ? r'$$' : r'\]';
    var line = first.substring(opening.end);
    final tex = StringBuffer();
    while (true) {
      final trimmed = line.trimRight();
      parser.advance();
      if (trimmed.endsWith(end)) {
        tex.write(trimmed.substring(0, trimmed.length - end.length));
        break;
      }
      tex.writeln(line);
      if (parser.isDone) break;
      line = parser.current.content;
    }
    return md.Element.empty(mathDisplayTag)
      ..attributes['tex'] = tex.toString().trim();
  }
}

class ChatMathBuilder extends MarkdownElementBuilder {
  final bool display;
  ChatMathBuilder({this.display = false});

  @override
  bool isBlockElement() => display;

  @override
  Widget visitElementAfterWithContext(BuildContext context, md.Element element,
      TextStyle? preferredStyle, TextStyle? parentStyle) {
    final tex = element.attributes['tex']!;
    final render = Math.tex(
      tex,
      mathStyle: display ? MathStyle.display : MathStyle.text,
      textStyle: parentStyle ?? Theme.of(context).textTheme.bodyMedium,
      onErrorFallback: (_) => Text(tex),
    );
    if (!display) return render;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: render,
    );
  }
}

Map<String, MarkdownElementBuilder> chatMathBuilders() => {
      mathInlineTag: ChatMathBuilder(),
      mathDisplayTag: ChatMathBuilder(display: true),
    };
