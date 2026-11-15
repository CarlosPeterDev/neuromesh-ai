import 'package:flutter_test/flutter_test.dart';
import 'package:neuromesh_ai/utils/bm25.dart';

void main() {
  test('chunks overlap and cover the text', () {
    final text = List.generate(200, (i) => 'Sentence number $i is here.').join(' ');
    final c = chunkText(text, size: 400, overlap: 50);
    expect(c.length, greaterThan(5));
    expect(c.every((p) => p.length <= 400), true);
    expect(c.first, startsWith('Sentence number 0'));
    expect(c.last, contains('199'));
  });

  test('ranks the matching chunk first', () {
    final chunks = [
      'The battery lasts ten hours on a full charge.',
      'Our refund policy allows returns within thirty days.',
      'The screen is a six inch OLED panel.',
    ];
    expect(bm25Top(chunks, 'how long are returns accepted refund').first, 1);
    expect(bm25Top(chunks, 'oled screen').first, 2);
  });

  test('no match returns empty', () {
    expect(bm25Top(['hello world'], 'zzz qqq'), isEmpty);
    expect(bm25Top([], 'x'), isEmpty);
  });

  test('works with Arabic', () {
    final chunks = ['سعر المنتج مئة جنيه', 'الشحن مجاني للطلبات الكبيرة'];
    expect(bm25Top(chunks, 'ما هو سعر المنتج').first, 0);
  });
}
