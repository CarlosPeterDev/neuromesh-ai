import 'package:flutter/widgets.dart';

/// RTL when the first letter in [text] is Arabic/Hebrew-script, else LTR.
TextDirection detectDirection(String text) {
  for (final r in text.runes) {
    if ((r >= 0x0590 && r <= 0x08FF) ||
        (r >= 0xFB1D && r <= 0xFDFF) ||
        (r >= 0xFE70 && r <= 0xFEFF)) {
      return TextDirection.rtl;
    }
    // First Latin letter decides LTR.
    if ((r >= 0x41 && r <= 0x5A) || (r >= 0x61 && r <= 0x7A)) {
      return TextDirection.ltr;
    }
  }
  return TextDirection.ltr;
}
