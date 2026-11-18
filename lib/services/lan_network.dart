import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

bool isPrivateLanAddress(String host) {
  final ip = InternetAddress.tryParse(host);
  if (ip == null || ip.type != InternetAddressType.IPv4 || ip.address != host) {
    return false;
  }
  final bytes = ip.rawAddress;
  return bytes[0] == 10 ||
      (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31) ||
      (bytes[0] == 192 && bytes[1] == 168);
}

http.Client lanHttpClient() =>
    IOClient(HttpClient()..findProxy = (_) => 'DIRECT');
