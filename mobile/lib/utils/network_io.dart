import 'dart:io';

Future<List<String>> listLocalIps() async {
  final interfaces = await NetworkInterface.list(
    type: InternetAddressType.IPv4,
    includeLoopback: false,
    includeLinkLocal: false,
  );
  final ips = <String>[];
  for (final iface in interfaces) {
    for (final addr in iface.addresses) {
      final ip = addr.address.trim();
      if (ip.isEmpty) {
        continue;
      }
      if (ip.startsWith('169.254.') || ip.startsWith('127.')) {
        continue;
      }
      ips.add(ip);
    }
  }
  return ips.toSet().toList();
}
