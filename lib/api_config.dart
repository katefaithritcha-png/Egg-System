import 'package:flutter/foundation.dart';

import 'offline_store.dart';

/// Where the phone/tablet talks to the farm PC.
/// Override at build time: `--dart-define=FARM_API_HOST=192.168.1.10`
class ApiConfig {
  static const int port = int.fromEnvironment('FARM_API_PORT', defaultValue: 8000);

  static const String _defineHost = String.fromEnvironment(
    'FARM_API_HOST',
    defaultValue: '',
  );

  /// Same address the ESP32 firmware uses in FARM_BACKEND_URL.
  /// For a hosted server, build with
  /// `--dart-define=FARM_API_URL=https://your-farm.example`
  /// and put that exact URL in the firmware too.
  static const String sharedFarmUrl = String.fromEnvironment(
    'FARM_API_URL',
    defaultValue: 'http://192.168.11.212:8000',
  );

  /// Older addresses of this PC. Kept as fallbacks if the shared URL is down.
  static const List<String> lanHosts = <String>[
    '192.168.11.212',
    '192.168.1.53',
    '192.168.88.10',
  ];

  static String get initialUrl =>
      sharedFarmUrl.isNotEmpty ? sharedFarmUrl : 'http://127.0.0.1:$port';

  static List<String> candidates({String? preferred}) {
    final List<String> urls = <String>[
      if (preferred != null && preferred.isNotEmpty) preferred,
      if (sharedFarmUrl.isNotEmpty) sharedFarmUrl,
      if (_defineHost.isNotEmpty) 'http://$_defineHost:$port',
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
