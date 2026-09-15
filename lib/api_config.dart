import 'package:flutter/foundation.dart';

import 'offline_store.dart';

/// Where the phone/tablet talks to the farm PC.
/// 127.0.0.1 only works on this computer or with USB `adb reverse`.
class ApiConfig {
  static const int port = 8000;

  /// Wi-Fi addresses of this development PC (update if they change).
  static const List<String> lanHosts = <String>[
    '192.168.11.212',
    '192.168.88.10',
  ];

  static String get initialUrl => 'http://127.0.0.1:$port';

  static List<String> candidates({String? preferred}) {
    final List<String> urls = <String>[
      if (preferred != null && preferred.isNotEmpty) preferred,
      if (kIsWeb) 'http://127.0.0.1:$port',
      'http://127.0.0.1:$port',
      'http://10.0.2.2:$port',
      ...lanHosts.map((String host) => 'http://$host:$port'),
    ];
    return urls.toSet().toList();
  }

  static Future<String?> discover({String? preferred}) async {
    final List<String> urls = candidates(preferred: preferred);
    final List<String?> hits = await Future.wait(
      urls.map((String url) async {
        final bool ok = await OfflineStore.ping(url);
        return ok ? url : null;
      }),
    );
    for (final String? hit in hits) {
      if (hit != null) {
        return hit;
      }
    }
    return null;
  }
}
