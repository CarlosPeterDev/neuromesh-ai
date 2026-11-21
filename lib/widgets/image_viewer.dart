import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:gal/gal.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

class ImageViewer extends StatefulWidget {
  final String base64Image;
  const ImageViewer({super.key, required this.base64Image});

  static Future<void> show(BuildContext context, String base64Image) =>
      showDialog(
          context: context,
          useSafeArea: false,
          barrierColor: Colors.black,
          builder: (_) => ImageViewer(base64Image: base64Image));

  static Future<void> showFile(BuildContext context, File file) async {
    try {
      final bytes = await file.readAsBytes();
      if (context.mounted) await show(context, base64Encode(bytes));
    } catch (error) {
      if (context.mounted)
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
            SnackBar(content: Text('Could not open image: $error')));
    }
  }

  @override
  State<ImageViewer> createState() => _ImageViewerState();
}

class _ImageViewerState extends State<ImageViewer> {
  late final Uint8List _bytes;
  late final String _extension;
  late final String _mime;
  bool _valid = false, _isSaving = false, _isSharing = false;

  @override
  void initState() {
    super.initState();
    try {
      _bytes = base64Decode(widget.base64Image);
    } catch (_) {
      _bytes = Uint8List(0);
    }
    try {
      _valid = img.decodeImage(_bytes) != null;
    } catch (_) {
      _valid = false;
    }
    _extension = _bytes.length >= 3 && _bytes[0] == 0xff && _bytes[1] == 0xd8
        ? 'jpg'
        : _bytes.length >= 12 &&
                ascii.decode(_bytes.sublist(0, 4), allowInvalid: true) == 'RIFF'
            ? 'webp'
            : _bytes.length >= 3 &&
                    ascii.decode(_bytes.sublist(0, 3), allowInvalid: true) ==
                        'GIF'
                ? 'gif'
                : _bytes.length >= 2 && _bytes[0] == 0x42 && _bytes[1] == 0x4d
                    ? 'bmp'
                    : 'png';
    _mime = 'image/${_extension == 'jpg' ? 'jpeg' : _extension}';
  }

  Future<void> _save() async {
    setState(() => _isSaving = true);
    try {
      if (!kIsWeb &&
          (defaultTargetPlatform == TargetPlatform.android ||
              defaultTargetPlatform == TargetPlatform.iOS)) {
        if (!await Gal.hasAccess() && !await Gal.requestAccess()) {
          throw StateError('Photo permission was denied.');
        }
        await Gal.putImageBytes(_bytes);
      } else {
        final path = await FilePicker.saveFile(
            dialogTitle: 'Save image',
            fileName: 'neuromesh_image.$_extension',
            bytes: _bytes);
        if (path == null) return;
        final target = File(path);
        await target.writeAsBytes(_bytes, flush: true);
        if (sha256.convert(await target.readAsBytes()) !=
            sha256.convert(_bytes)) {
          throw StateError('Saved image could not be verified.');
        }
      }
      if (mounted)
        _notify(!kIsWeb &&
                (defaultTargetPlatform == TargetPlatform.android ||
                    defaultTargetPlatform == TargetPlatform.iOS)
            ? 'Image saved to gallery'
            : 'Image saved');
    } catch (error) {
      if (mounted) _notify('Image was not saved: $error');
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _share() async {
    setState(() => _isSharing = true);
    try {
      final dir = await getTemporaryDirectory();
      final file = File(
          '${dir.path}/neuromesh_${DateTime.now().microsecondsSinceEpoch}.$_extension');
      await file.writeAsBytes(_bytes, flush: true);
      if (sha256.convert(await file.readAsBytes()) != sha256.convert(_bytes))
        throw StateError('Share image could not be verified.');
      if (!mounted) return;
      final box = context.findRenderObject() as RenderBox?;
      await Share.shareXFiles([XFile(file.path, mimeType: _mime)],
          text: 'Generated with NeuroMesh AI',
          sharePositionOrigin:
              box == null ? null : box.localToGlobal(Offset.zero) & box.size);
    } catch (error) {
      if (mounted) _notify('Image was not shared: $error');
    } finally {
      if (mounted) setState(() => _isSharing = false);
    }
  }

  void _notify(String text) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.hideCurrentSnackBar();
    messenger?.showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: Colors.black,
        body: Stack(fit: StackFit.expand, children: [
          InteractiveViewer(
              minScale: 0.5,
              maxScale: 5,
              child: Center(
                  child: _valid
                      ? Image.memory(_bytes, fit: BoxFit.contain)
                      : const Text('This image could not be opened.',
                          style: TextStyle(color: Colors.white)))),
          SafeArea(
              child: Align(
                  alignment: Alignment.topLeft,
                  child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: IconButton.filledTonal(
                          tooltip: 'Close',
                          icon: const Icon(Icons.close),
                          onPressed: () => Navigator.of(context).pop())))),
          SafeArea(
              child: Align(
                  alignment: Alignment.bottomCenter,
                  child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        FilledButton.icon(
                            onPressed: !_valid || _isSaving || _isSharing
                                ? null
                                : _save,
                            icon: _isSaving
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2))
                                : const Icon(Icons.download_outlined),
                            label: const Text('Save')),
                        const SizedBox(width: 12),
                        FilledButton.icon(
                            onPressed: !_valid || _isSaving || _isSharing
                                ? null
                                : _share,
                            icon: _isSharing
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2))
                                : const Icon(Icons.share_outlined),
                            label: const Text('Share')),
                      ])))),
        ]),
      );
}
