import 'package:flutter_test/flutter_test.dart';
import 'package:neuromesh_ai/utils/image_bundle.dart';

void main() {
  test('roles are read from file names', () {
    expect(roleOfFile('z_image_turbo-Q4_K_M.gguf'), BundleRole.diffusion);
    expect(roleOfFile('ae.safetensors'), BundleRole.vae);
    expect(roleOfFile('split_files/vae/ae.safetensors'), BundleRole.vae);
    expect(roleOfFile('clip_l.safetensors'), BundleRole.clipL);
    expect(roleOfFile('t5xxl_fp8_e4m3fn.safetensors'), BundleRole.t5xxl);
    expect(roleOfFile('qwen_3_4b.safetensors'), BundleRole.llm);
    expect(roleOfFile('readme.md'), BundleRole.other);
    expect(roleOfFile('sd15-model.safetensors'), BundleRole.checkpoint);
  });

  test('bundle resolves components', () {
    final b = resolveBundle([
      'flux1-dev-Q4_0.gguf',
      'ae.safetensors',
      'clip_l.safetensors',
      't5xxl_Q8_0.gguf'
    ]);
    expect(b.diffusion, 'flux1-dev-Q4_0.gguf');
    expect(b.model, '');
    expect(b.vae, 'ae.safetensors');
    expect(b.t5xxl, 't5xxl_Q8_0.gguf');
    expect(b.extraPaths.keys, containsAll(['diffusion', 't5xxl']));
  });

  test('single checkpoint stays a plain model', () {
    final b = resolveBundle(['sd_turbo.safetensors']);
    expect(b.model, 'sd_turbo.safetensors');
    expect(b.diffusion, '');
    expect(b.isValid, true);
  });

  test('Diffusers layouts resolve CLIP, VAE and diffusion by family', () {
    final bundle = resolveBundle([
      'sdxl.sdbundle/unet/diffusion_pytorch_model.safetensors',
      'sdxl.sdbundle/vae/diffusion_pytorch_model.safetensors',
      'sdxl.sdbundle/text_encoder/model.safetensors',
      'sdxl.sdbundle/text_encoder_2/model.safetensors',
    ]);
    expect(bundle.diffusion, contains('/unet/'));
    expect(bundle.vae, contains('/vae/'));
    expect(bundle.clipL, contains('/text_encoder/'));
    expect(bundle.clipG, contains('/text_encoder_2/'));
    expect(
        roleOfFile('text_encoder_2/model.safetensors',
            familyHint: 'FLUX.1-dev'),
        BundleRole.t5xxl);
  });

  test('recommend prefers small quant and adds helpers', () {
    final r = recommendBundle({
      'flux1-dev-Q8_0.gguf': 12000,
      'flux1-dev-Q4_0.gguf': 6500,
      'ae.safetensors': 300,
      'clip_l.safetensors': 250,
    });
    expect(r, ['flux1-dev-Q4_0.gguf', 'ae.safetensors', 'clip_l.safetensors']);
  });
}
