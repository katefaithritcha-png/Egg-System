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
  /// Hosted Cloudflare Worker (same origin proxies /api + /metrics when
  /// FARM_ORIGIN is set on the Worker). LAN default for phones on farm Wi‑Fi.
  static const String sharedFarmUrl = String.fromEnvironment(
    'FARM_API_URL',
    defaultValue: 'http://192.168.11.212:8000',
  );

  /// Public Workers URL used when building the web app for Cloudflare.
  static const String workersFarmUrl =
      'https://egg-system.paghasianjustine.workers.dev';

  /// Cloudflare Tunnel hostname for the farm PC (camera /live.jpg).
  /// Prefer this for snapshot polling — workers.dev rate-limits (429) under
  /// fast /live.jpg refresh; the tunnel serves JPEGs with CORS *.
  static const String farmTunnelUrl = 'https://egg-farm.eggsorting.site';

  /// Older addresses of this PC. Kept as fallbacks if the shared URL is down.
  static const List<String> lanHosts = <String>[
    '192.168.11.212',
    '192.168.1.53',
    '192.168.88.10',
  ];

  /// When the Flutter web app is opened from workers.dev / tunnel HTTPS,
  /// call the same origin so the Worker proxies to the farm (no mixed content).
  static String? get hostedOrigin {
    if (!kIsWeb) {
      return null;
    }
    final Uri base = Uri.base;
    if (base.scheme == 'https' &&
        (base.host.endsWith('workers.dev') ||
            base.host.endsWith('trycloudflare.com') ||
            base.host.endsWith('eggsorting.com') ||
            base.host.endsWith('eggsorting.site'))) {
      return '${base.scheme}://${base.host}';
    }
    return null;
  }

  /// True when the browser page is HTTPS public hosting — LAN http is blocked.
  static bool get isHostedHttpsWeb => hostedOrigin != null;

  /// Auth / metrics / camera API base.
  /// When the UI is on workers.dev, talk to the farm tunnel directly — the
  /// Worker proxy returns HTTP 429 under load (login + live.jpg both fail).
  static String get apiBaseUrl {
    if (!isHostedHttpsWeb) {
      return initialUrl;
    }
    final String hosted = hostedOrigin!;
    // Page already on the farm tunnel hostname — same origin.
    if (hosted.contains('eggsorting.site') ||
        hosted.contains('trycloudflare.com')) {
      return hosted;
    }
    return farmTunnelUrl;
  }

  static bool isInsecureLanUrl(String url) {
    final String u = url.toLowerCase();
    return u.startsWith('http://192.168.') ||
        u.startsWith('http://10.') ||
        u.startsWith('http://127.0.0.1') ||
        u.startsWith('http://localhost');
  }

  static String get initialUrl {
    if (isHostedHttpsWeb) {
      return apiBaseUrl;
    }
    // Farm LAN / tunnel only — never localhost.
    return sharedFarmUrl.isNotEmpty
        ? sharedFarmUrl
        : 'http://${lanHosts.first}:$port';
  }

  static List<String> candidates({String? preferred}) {
    // Hosted HTTPS page: never probe LAN http — browser blocks mixed content
    // and floods the console with failed 192.168.* /auth/health requests.
    if (isHostedHttpsWeb) {
      final String hosted = hostedOrigin!;
      return <String>[
        farmTunnelUrl,
        if (hosted != farmTunnelUrl) hosted,
        if (workersFarmUrl != hosted && workersFarmUrl != farmTunnelUrl)
          workersFarmUrl,
      ];
    }

    final List<String> urls = <String>[
      if (preferred != null && preferred.isNotEmpty) preferred,
      if (sharedFarmUrl.isNotEmpty) sharedFarmUrl,
      workersFarmUrl,
      if (_defineHost.isNotEmpty) 'http://$_defineHost:$port',
      ...lanHosts.map((String host) => 'http://$host:$port'),
    ];
    return urls.where((String u) => u.isNotEmpty).toSet().toList();
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
