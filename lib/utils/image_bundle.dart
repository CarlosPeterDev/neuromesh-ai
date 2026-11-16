/// Components of a multi-file image model (Flux, Z-Image, SD3, Qwen-Image…).
class ImageBundle {
  /// Full single-file checkpoint (SD 1.5 / SDXL style), when there is no
  /// separate diffusion model.
  final String model;
  final String diffusion;
  final String vae;
  final String clipL;
  final String clipG;
  final String t5xxl;
  final String llm;

  const ImageBundle({
    this.model = '',
    this.diffusion = '',
    this.vae = '',
    this.clipL = '',
    this.clipG = '',
    this.t5xxl = '',
    this.llm = '',
  });

  bool get isValid => model.isNotEmpty || diffusion.isNotEmpty;

  Map<String, String> get extraPaths => {
        if (diffusion.isNotEmpty) 'diffusion': diffusion,
        if (t5xxl.isNotEmpty) 't5xxl': t5xxl,
        if (llm.isNotEmpty) 'llm': llm,
        if (clipG.isNotEmpty) 'clipG': clipG,
      };
}

enum BundleRole { diffusion, vae, clipL, clipG, t5xxl, llm, checkpoint, other }

/// Which part of a model a file is, judged from its name.
BundleRole roleOfFile(String path) {
  final n = path.split('/').last.toLowerCase();
  final all = path.toLowerCase();
  if (!(n.endsWith('.safetensors') || n.endsWith('.gguf'))) return BundleRole.other;
  if (n.contains('taesd') || n.contains('taef')) return BundleRole.other;
  if (RegExp(r'(^|[^a-z])(ae|vae)([^a-z]|$)').hasMatch(n) ||
      n.contains('vae') ||
      all.contains('/vae/')) {
    return BundleRole.vae;
  }
  if (n.contains('clip_l') || n.contains('clip-l') || n.contains('clipl')) {
    return BundleRole.clipL;
  }
  if (n.contains('clip_g') || n.contains('clip-g') || n.contains('clipg')) {
    return BundleRole.clipG;
  }
  if (n.contains('t5xxl') || n.contains('t5-xxl') || n.contains('umt5') || all.contains('/text_encoder_2/')) {
    return BundleRole.t5xxl;
  }
  if (n.contains('qwen') && !n.contains('image') && (n.contains('3') || n.contains('2.5') || n.contains('vl') || all.contains('text_encoder'))) {
    return BundleRole.llm;
  }
  if (n.contains('gemma') || n.contains('mistral') || n.contains('llama') || all.contains('/text_encoder/')) {
    return BundleRole.llm;
  }
  if (all.contains('/transformer/') ||
      all.contains('/unet/') ||
      n.contains('diffusion') ||
      n.contains('unet') ||
      n.contains('flux') ||
      n.contains('z_image') ||
      n.contains('z-image') ||
      n.contains('zimage') ||
      n.contains('sd3') ||
      n.contains('chroma') ||
      n.contains('qwen_image') ||
      n.contains('qwen-image')) {
    return BundleRole.diffusion;
  }
  return BundleRole.checkpoint;
}

/// Picks the components out of the files of one model folder
/// (paths relative to the folder or absolute). When several files share a
/// role the biggest-name-sorted first wins; sizes are used when given.
ImageBundle resolveBundle(List<String> files, {Map<String, int> sizes = const {}}) {
  String pick(BundleRole role) {
    final c = files.where((f) => roleOfFile(f) == role).toList()
      ..sort((a, b) => (sizes[b] ?? 0).compareTo(sizes[a] ?? 0));
    return c.isEmpty ? '' : c.first;
  }

  final diffusion = pick(BundleRole.diffusion);
  final checkpoint = pick(BundleRole.checkpoint);
  return ImageBundle(
    model: diffusion.isEmpty ? checkpoint : '',
    diffusion: diffusion,
    vae: pick(BundleRole.vae),
    clipL: pick(BundleRole.clipL),
    clipG: pick(BundleRole.clipG),
    t5xxl: pick(BundleRole.t5xxl),
    llm: pick(BundleRole.llm),
  );
}

/// Chooses a sensible set of files to download from a repository listing:
/// the smallest diffusion/checkpoint file plus the helpers it needs, with a
/// quantised variant preferred over a huge full-precision one.
List<String> recommendBundle(Map<String, int> sizes, {int maxBytes = 6 * 1024 * 1024 * 1024}) {
  final files = sizes.keys.toList();
  String? best(BundleRole role, {bool preferSmall = true}) {
    final c = files.where((f) => roleOfFile(f) == role).toList();
    if (c.isEmpty) return null;
    c.sort((a, b) {
      int score(String f) {
        final n = f.toLowerCase();
        var s = 0;
        if (n.contains('q4_k_m') || n.contains('q4_0') || n.contains('q4_k_s')) s -= 3;
        if (n.contains('q5')) s -= 2;
        if (n.contains('q8')) s -= 1;
        if (n.contains('fp8') || n.contains('int8')) s -= 1;
        return s;
      }

      final d = score(a).compareTo(score(b));
      if (d != 0) return d;
      return (sizes[a] ?? 0).compareTo(sizes[b] ?? 0);
    });
    return c.first;
  }

  final out = <String>[];
  final diff = best(BundleRole.diffusion);
  final ckpt = diff == null ? best(BundleRole.checkpoint) : null;
  if (diff != null) out.add(diff);
  if (ckpt != null) out.add(ckpt);
  for (final r in [BundleRole.vae, BundleRole.clipL, BundleRole.clipG, BundleRole.t5xxl, BundleRole.llm]) {
    final f = best(r);
    if (f != null) out.add(f);
  }
  return out;
}
