import 'llama_archs.dart';

enum ModelFileRole {
  model('Main model', 'Contains the model weights used for inference.'),
  projector('Vision helper',
      'Adds image input to a compatible vision model. Attach it to its matching model, then reload.'),
  draft('Speed helper',
      'Draft weights for faster generation. Requires a matching main model and a runtime with the required speculative-decoding support. Draft attachment is not available in this build.'),
  adapter('LoRA adapter',
      'Changes a compatible base model. Load with the matching model and an adapter-capable runtime. Standalone adapter loading is not supported here.'),
  imageAddon('Image helper',
      'An image-model component. Add matching components through the image bundle picker. Compatibility depends on the model and runtime.');

  const ModelFileRole(this.label, this.help);
  final String label;
  final String help;
  bool get isHelper => this != model;
}

ModelFileRole modelFileRole(String path) {
  final name = path.split(RegExp(r'[/\\]')).last.toLowerCase();
  if (name.endsWith('.gguf') && name.contains('mmproj')) {
    return ModelFileRole.projector;
  }
  if (isFastMtpDraft(name)) {
    return ModelFileRole.draft;
  }
  if (RegExp(r'(^|[-_.])(lora|adapter_model)([-_.]|$)').hasMatch(name)) {
    return ModelFileRole.adapter;
  }
  if ((name.endsWith('.safetensors') || name.endsWith('.gguf')) &&
      (RegExp(r'(^|[-_.])(vae|taesd|controlnet|clip_l|clip_g|t5xxl)([-_.]|$)')
              .hasMatch(name) ||
          path.toLowerCase().split(RegExp(r'[/\\]')).any((part) => const {
                'vae',
                'text_encoder',
                'text_encoder_2',
                'text_encoders',
                'controlnet'
              }.contains(part)))) {
    return ModelFileRole.imageAddon;
  }
  return ModelFileRole.model;
}

String? huggingFaceRepository(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host != 'huggingface.co' ||
      uri.userInfo.isNotEmpty ||
      uri.hasPort) return null;
  final parts = uri.pathSegments;
  if (parts.length < 2 ||
      parts
          .take(2)
          .any((p) => !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]*$').hasMatch(p)))
    return null;
  return '${parts[0]}/${parts[1]}';
}
