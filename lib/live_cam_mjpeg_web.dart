import 'dart:async';
import 'dart:collection';
import 'dart:html' as html;
import 'dart:ui_web' as ui_web;

import 'package:flutter/material.dart';

import 'api_config.dart';

class LiveCamMjpeg extends StatefulWidget {
  const LiveCamMjpeg({
    super.key,
    required this.streamUrl,
    this.pollSnapshots = false,
  });

  final String streamUrl;

  /// Prefer true on hosted web — multipart /stream dies on Cloudflare tunnels.
  final bool pollSnapshots;

  @override
  State<LiveCamMjpeg> createState() => _LiveCamMjpegState();
}

class _LiveCamMjpegState extends State<LiveCamMjpeg> {
  late final String _viewType;
  html.ImageElement? _image;
  html.ImageElement? _pollImgA;
  html.ImageElement? _pollImgB;
  html.DivElement? _root;
  bool _useA = true;
  bool _hasPaint = false;
  bool _run = true;
  int _urlIndex = 0;
  bool _fetching = false;
  int _frameGen = 0;

  List<String> get _snapshotBases {
    final String primary = widget.streamUrl
        .replaceFirst(RegExp(r'/stream/?$'), '/live.jpg')
        .replaceFirst(RegExp(r'\?.*$'), '');
    final LinkedHashSet<String> bases = LinkedHashSet<String>();
    // Hosted: farm tunnel only — workers.dev rate-limits live polls.
    if (ApiConfig.isHostedHttpsWeb) {
      bases.add('${ApiConfig.farmTunnelUrl}/live.jpg');
      if (primary.contains('eggsorting.site')) {
        bases.add(primary);
      }
    } else {
      bases.add(primary);
    }
    return bases.toList();
  }

  String _bust(String base) =>
      '$base?t=${DateTime.now().millisecondsSinceEpoch}&smooth=1';

  html.ImageElement _makeLayer() {
    return html.ImageElement()
      ..style.border = 'none'
      ..style.position = 'absolute'
      ..style.left = '0'
      ..style.top = '0'
      ..style.width = '100%'
      ..style.height = '100%'
      ..style.objectFit = 'contain'
      ..style.setProperty('image-rendering', 'high-quality')
      ..style.overflow = 'hidden'
      ..style.display = 'block'
      ..style.backgroundColor = 'transparent'
      ..style.opacity = '0'
      // Longer fade hides ~1–2 fps tunnel stutter without looking blurry.
      ..style.transition = 'opacity 120ms linear'
      ..draggable = false;
  }

  void _showLayer(html.ImageElement next, html.ImageElement prev) {
    next.style.opacity = '1';
    prev.style.opacity = '0';
    _hasPaint = true;
    _frameGen++;
  }

  Future<void> _pollSnapshots() async {
    // Browser loads JPEG directly (no Dart http→blob hop) for lower lag.
    Duration gap = ApiConfig.isHostedHttpsWeb
        ? const Duration(milliseconds: 20)
        : const Duration(milliseconds: 15);
    int missStreak = 0;
    while (_run && mounted && widget.pollSnapshots) {
      if (_fetching) {
        await Future<void>.delayed(const Duration(milliseconds: 8));
        continue;
      }
      final List<String> bases = _snapshotBases;
      if (bases.isEmpty) {
        await Future<void>.delayed(gap);
        continue;
      }
      final String base = bases[_urlIndex % bases.length];
      final String url = _bust(base);
      final html.ImageElement? a = _pollImgA;
      final html.ImageElement? b = _pollImgB;
      if (a == null || b == null) {
        await Future<void>.delayed(gap);
        continue;
      }
      final html.ImageElement target = _useA ? a : b;
      final html.ImageElement other = _useA ? b : a;
      _fetching = true;
      final Stopwatch sw = Stopwatch()..start();
      final Completer<bool> done = Completer<bool>();
      late final StreamSubscription<html.Event> okSub;
      late final StreamSubscription<html.Event> errSub;
      okSub = target.onLoad.listen((_) {
        if (!done.isCompleted) {
          done.complete(true);
        }
      });
      errSub = target.onError.listen((_) {
        if (!done.isCompleted) {
          done.complete(false);
        }
      });
      target.src = url;
      bool ok = false;
      try {
        ok = await done.future.timeout(const Duration(seconds: 3), onTimeout: () => false);
      } finally {
        await okSub.cancel();
        await errSub.cancel();
        _fetching = false;
      }
      final int rttMs = sw.elapsedMilliseconds;
      if (ok) {
        _showLayer(target, other);
        _useA = !_useA;
        missStreak = 0;
        if (mounted && (_frameGen == 1 || _frameGen % 10 == 0)) {
          setState(() {});
        }
        if (ApiConfig.isHostedHttpsWeb) {
          if (rttMs > 2000 || missStreak >= 5) {
            gap = const Duration(milliseconds: 280);
          } else if (rttMs > 900) {
            gap = const Duration(milliseconds: 80);
          } else {
            // Aim ~100–150 ms UI cadence when origin is fresh.
            gap = Duration(milliseconds: rttMs < 200 ? 0 : (rttMs < 350 ? 8 : 20));
          }
        } else {
          gap = const Duration(milliseconds: 8);
        }
      } else {
        missStreak++;
        _urlIndex = (_urlIndex + 1) % bases.length;
        gap = Duration(milliseconds: ApiConfig.isHostedHttpsWeb ? 400 : 120);
      }
      await Future<void>.delayed(gap);
    }
  }

  void _paintStream() {
    final html.ImageElement? image = _image;
    if (image == null) {
      return;
    }
    image.src = widget.streamUrl;
  }

  html.ImageElement _makeImg(String src) {
    return html.ImageElement()
      ..style.border = 'none'
      ..style.width = '100%'
      ..style.height = '100%'
      ..style.maxWidth = '100%'
      ..style.maxHeight = '100%'
      ..style.objectFit = 'contain'
      ..style.setProperty('image-rendering', 'high-quality')
      ..style.overflow = 'hidden'
      ..style.display = 'block'
      ..style.backgroundColor = '#211A16'
      ..src = src;
  }

  @override
  void initState() {
    super.initState();
    _viewType = 'live-cam-${identityHashCode(this)}';
    if (widget.pollSnapshots) {
      ui_web.platformViewRegistry.registerViewFactory(_viewType, (int viewId) {
        final html.DivElement root = html.DivElement()
          ..style.position = 'relative'
          ..style.width = '100%'
          ..style.height = '100%'
          ..style.overflow = 'hidden'
          ..style.backgroundColor = '#211A16';
        final html.ImageElement a = _makeLayer();
        final html.ImageElement b = _makeLayer();
        root.append(a);
        root.append(b);
        _root = root;
        _pollImgA = a;
        _pollImgB = b;
        return root;
      });
      unawaited(_pollSnapshots());
      return;
    }
    ui_web.platformViewRegistry.registerViewFactory(_viewType, (int viewId) {
      final html.ImageElement image = _makeImg(widget.streamUrl);
      _image = image;
      return image;
    });
  }

  @override
  void didUpdateWidget(LiveCamMjpeg oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.streamUrl != widget.streamUrl && !widget.pollSnapshots) {
      _paintStream();
    }
  }

  @override
  void dispose() {
    _run = false;
    _root = null;
    _pollImgA = null;
    _pollImgB = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.pollSnapshots) {
      return Stack(
        fit: StackFit.expand,
        children: <Widget>[
          HtmlElementView(viewType: _viewType),
          if (!_hasPaint)
            const Center(
              child: Text(
                'Waiting for internet camera…',
                style: TextStyle(color: Color(0xFF9A8F88), fontSize: 12),
              ),
            ),
        ],
      );
    }
    return HtmlElementView(viewType: _viewType);
  }
}
