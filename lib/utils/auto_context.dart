/// Picks a context size that should fit in memory. It only ever *lowers*
/// the user's requested size, so it can't make things worse.
///
/// Rough model: KV cache per 1,000 tokens grows with model size.
int autoContextSize({
  required int requested,
  required double availableGb,
  required int modelBytes,
  int minContext = 512,
}) {
  if (availableGb <= 0 || modelBytes <= 0) return requested;
  final modelGb = modelBytes / (1024 * 1024 * 1024);
  // Keep a safety margin: Android needs headroom, and mmap'd weights count.
  final budget = availableGb * 0.7 - modelGb - 0.4;
  final kvPer1k = (0.06 * modelGb).clamp(0.03, 0.5);
  if (budget <= 0) return minContext;
  final fit = ((budget / kvPer1k) * 1024).floor();
  final rounded = (fit ~/ 256) * 256;
  final capped = rounded < requested ? rounded : requested;
  return capped < minContext ? minContext : capped;
}
