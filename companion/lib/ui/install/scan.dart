import 'dart:async';
import 'dart:io';
import 'dart:math';

final _notWifi = RegExp(
  r'^(lo|tun|tap|ppp|rmnet|ccmni|clat|v4-|docker|veth|br-|virbr|dummy|wg|ipsec|utun|bridge|awdl|llw|vEthernet|VMware|VirtualBox)',
);

/// This device's own Wi-Fi address from (interface name, IPv4) pairs: a
/// phone's wlan, a Mac's en0, a Windows PC's Wi-Fi.
String? pickIpv4(Iterable<(String, String)> addresses) {
  final ok = [
    for (final (name, ip) in addresses)
      if (!_notWifi.hasMatch(name) &&
          !ip.startsWith('127.') &&
          !ip.startsWith('169.254.'))
        (name, ip),
  ];
  for (final (name, ip) in ok) {
    if (name.startsWith('wlan') || name == 'en0' || name == 'Wi-Fi') {
      return ip;
    }
  }
  return ok.isEmpty ? null : ok.first.$2;
}

List<String> subnetHosts(String ip) {
  final prefix = ip.substring(0, ip.lastIndexOf('.') + 1);
  return [
    for (var i = 1; i < 255; i++)
      if ('$prefix$i' != ip) '$prefix$i',
  ];
}

/// Hosts on the phone's /24 with ADB (TCP 5555) open, as they answer. Cancelling stops it after the batch in flight.
Stream<String> scanSubnet() {
  var cancelled = false;
  final out = StreamController<String>(onCancel: () => cancelled = true);
  out.onListen = () async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
      );
      final ip = pickIpv4([
        for (final i in interfaces)
          for (final a in i.addresses) (i.name, a.address),
      ]);
      if (ip == null) return;
      final hosts = subnetHosts(ip);
      for (var i = 0; i < hosts.length && !cancelled; i += 32) {
        final found = await Future.wait(
          hosts.sublist(i, min(i + 32, hosts.length)).map(_adbOpen),
        );
        for (final h in found) {
          if (h != null && !cancelled) out.add(h);
        }
      }
    } catch (e) {
      if (!cancelled) out.addError(e);
    } finally {
      out.close();
    }
  };
  return out.stream;
}

Future<String?> _adbOpen(String host) async {
  try {
    final s = await Socket.connect(
      host,
      5555,
      timeout: const Duration(milliseconds: 300),
    );
    s.destroy();
    return host;
  } on SocketException {
    return null;
  }
}
