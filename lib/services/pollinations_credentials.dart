import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class PollinationsCredentials {
  static const _storage = FlutterSecureStorage();
  static const _setting = 'pollinations_image_key';

  static Future<String?> read() => _storage.read(key: _setting);

  static Future<void> save(String key) => key.trim().isEmpty
      ? _storage.delete(key: _setting)
      : _storage.write(key: _setting, value: key.trim());
}
