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

http.Client lanHttpClient({String? sourceAddress}) {
  final client = HttpClient()..findProxy = (_) => 'DIRECT';
  if (sourceAddress != null) {
    client.connectionFactory = (uri, _, __) => Socket.startConnect(
        uri.host, uri.port,
        sourceAddress: InternetAddress(sourceAddress));
  }
  return IOClient(client);
}

/// Retry using the local Wi-Fi or Ethernet IP closest to the peer address.
/// This is a preference for choosing a source address, not a subnet test.
List<String> lanSourceAddresses(String peer, Iterable<LanEndpoint> endpoints) {
  final target = InternetAddress.tryParse(peer);
  if (target == null || !isPrivateLanAddress(peer)) return [];
  int prefixLength(String source) {
    final bytes = InternetAddress(source).rawAddress;
    var bits = 0;
    for (var i = 0; i < bytes.length; i++) {
      final difference = bytes[i] ^ target.rawAddress[i];
      if (difference != 0) return bits + 8 - difference.bitLength;
      bits += 8;
    }
    return bits;
  }

  final sources = [
    for (final (index, entry) in sortLanEndpoints(endpoints).indexed)
      if (entry.address != peer)
        (
          address: entry.address,
          index: index,
          prefix: prefixLength(entry.address)
        ),
  ]..sort((a, b) {
      final prefix = b.prefix.compareTo(a.prefix);
      return prefix == 0 ? a.index.compareTo(b.index) : prefix;
    });
  return sources.map((entry) => entry.address).toList();
}

typedef LanEndpoint = ({String address, String interfaceName});

/// Prefer Wi-Fi client and hotspot interfaces. Tunnel, cellular and virtual
/// bridge addresses cannot usually be reached from the other device.
List<LanEndpoint> sortLanEndpoints(Iterable<LanEndpoint> candidates) {
  final excluded = RegExp(
      r'^(tun|tap|utun|ppp|wg[0-9]|tailscale|rmnet|ccmni|pdp_ip|veth|docker|virbr|dummy|lo$)',
      caseSensitive: false);
  int priority(String name) {
    final lower = name.toLowerCase();
    if (RegExp(r'^(wlan|wlp|wifi|wi-fi)|^en0$').hasMatch(lower)) return 0;
    if (RegExp(r'^(ap\d|softap|swlan|wlanap|rndis)').hasMatch(lower)) return 1;
    return 2;
  }

  final endpoints = candidates
      .where((entry) =>
          isPrivateLanAddress(entry.address) &&
          !excluded.hasMatch(entry.interfaceName))
      .toList()
    ..sort((a, b) {
      final rank =
          priority(a.interfaceName).compareTo(priority(b.interfaceName));
      if (rank != 0) return rank;
      final name = a.interfaceName.compareTo(b.interfaceName);
      return name == 0 ? a.address.compareTo(b.address) : name;
    });
  final seen = <String>{};
  return endpoints.where((entry) => seen.add(entry.address)).toList();
}

Future<List<LanEndpoint>> lanIpv4Endpoints() async {
  try {
    final interfaces =
        await NetworkInterface.list(type: InternetAddressType.IPv4);
    return sortLanEndpoints([
      for (final interface in interfaces)
        for (final address in interface.addresses)
          (address: address.address, interfaceName: interface.name),
    ]);
  } on SocketException {
    return [];
  }
}

Future<String?> lanAddress() async =>
    (await lanIpv4Endpoints()).firstOrNull?.address;

/// Shared recovery instructions for the same LAN path used by transfer and RPC.
const lanConnectionHelp =
    'Keep both devices on the same Wi-Fi or hotspot. On guest Wi-Fi, device isolation can block pairing. Reopen the sender or worker screen and use its current address.';
