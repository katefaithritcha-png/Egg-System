import 'package:flutter/foundation.dart';

import 'offline_store.dart';

/// Cloudflare-only farm API. No localhost / LAN bases for clients.
class ApiConfig {
  /// Public Workers UI (same-origin proxies API when FARM_ORIGIN is set).
  static const String workersFarmUrl =
      'https://egg-system.paghasianjustine.workers.dev';

  /// Cloudflare Tunnel hostname — CAM push + live.jpg + farm API.
  static const String farmTunnelUrl = 'https://egg-farm.eggsorting.site';

  /// Override at build: `--dart-define=FARM_API_URL=https://egg-farm.eggsorting.site`
  static const String sharedFarmUrl = String.fromEnvironment(
    'FARM_API_URL',
    defaultValue: farmTunnelUrl,
  );

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

  /// True when the browser page is HTTPS public hosting.
  static bool get isHostedHttpsWeb => hostedOrigin != null;

  /// Auth / metrics / camera API base — Cloudflare only.
  static String get apiBaseUrl {
    if (isHostedHttpsWeb) {
      return hostedOrigin!;
    }
    if (sharedFarmUrl.startsWith('https://')) {
      return sharedFarmUrl;
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

  static String get initialUrl => apiBaseUrl;

  /// Only public Cloudflare endpoints — never localhost or LAN.
  static List<String> candidates({String? preferred}) {
    final String hosted = hostedOrigin ?? '';
    final List<String> urls = <String>[
      if (preferred != null &&
          preferred.isNotEmpty &&
          preferred.startsWith('https://') &&
          !isInsecureLanUrl(preferred))
        preferred,
      if (hosted.isNotEmpty) hosted,
      workersFarmUrl,
      farmTunnelUrl,
      if (sharedFarmUrl.startsWith('https://') &&
          !isInsecureLanUrl(sharedFarmUrl))
        sharedFarmUrl,
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
