import 'dart:async';
import 'dart:collection';
import 'dart:html' as html;
import 'dart:typed_data';
import 'dart:ui_web' as ui_web;

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

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
  Uint8List? _jpg;
  String? _netUrl;
  bool _run = true;
  int _urlIndex = 0;

  List<String> get _snapshotBases {
    final String primary = widget.streamUrl
        .replaceFirst(RegExp(r'/stream/?$'), '/live.jpg')
        .replaceFirst(RegExp(r'\?.*$'), '');
    final LinkedHashSet<String> bases = LinkedHashSet<String>();
    bases.add(primary);
    if (ApiConfig.isHostedHttpsWeb) {
      bases.add('${ApiConfig.farmTunnelUrl}/live.jpg');
      bases.add('${ApiConfig.workersFarmUrl}/live.jpg');
    }
    return bases.toList();
  }

  String _bust(String base) =>
      '$base?t=${DateTime.now().millisecondsSinceEpoch}';

  Future<void> _pollSnapshots() async {
    Duration gap = const Duration(milliseconds: 800);
    while (_run && mounted && widget.pollSnapshots) {
      final List<String> bases = _snapshotBases;
      if (bases.isEmpty) {
        await Future<void>.delayed(gap);
        continue;
      }
      final String base = bases[_urlIndex % bases.length];
      final String url = _bust(base);
      bool gotFrame = false;
      try {
        // No custom headers — Cache-Control triggers CORS preflight and
        // fails against the farm tunnel (only Authorization/Content-Type allowed).
        final http.Response res = await http
            .get(Uri.parse(url))
            .timeout(const Duration(seconds: 8));
        final Uint8List jpg = res.bodyBytes;
        if (res.statusCode == 429) {
          _urlIndex = (_urlIndex + 1) % bases.length;
          gap = const Duration(seconds: 2);
        } else if (res.statusCode == 200 &&
            jpg.length > 2 &&
            jpg[0] == 0xFF &&
            jpg[1] == 0xD8 &&
            mounted) {
          setState(() {
            _jpg = jpg;
            _netUrl = null;
          });
          gotFrame = true;
          gap = const Duration(milliseconds: 800);
        } else {
          _urlIndex = (_urlIndex + 1) % bases.length;
          gap = const Duration(seconds: 1);
        }
      } catch (_) {
        // Fallback: show via Image.network (display-only, no byte CORS).
        if (mounted) {
          setState(() => _netUrl = url);
        }
        _urlIndex = (_urlIndex + 1) % bases.length;
        gap = const Duration(seconds: 1);
      }
      if (!gotFrame && _jpg == null && _netUrl == null && mounted) {
        setState(() => _netUrl = url);
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

  @override
  void initState() {
    super.initState();
    if (widget.pollSnapshots) {
      unawaited(_pollSnapshots());
      return;
    }
    _viewType = 'live-cam-${identityHashCode(this)}';
    ui_web.platformViewRegistry.registerViewFactory(_viewType, (int viewId) {
      final html.ImageElement image = html.ImageElement()
        ..style.border = 'none'
        ..style.width = '100%'
        ..style.height = '100%'
        ..style.maxWidth = '100%'
        ..style.maxHeight = '100%'
        ..style.objectFit = 'contain'
        ..style.overflow = 'hidden'
        ..style.display = 'block'
        ..style.backgroundColor = '#211A16'
        ..src = widget.streamUrl;
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
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.pollSnapshots) {
      final Uint8List? jpg = _jpg;
      if (jpg != null) {
        return SizedBox.expand(
          child: Image.memory(
            jpg,
            fit: BoxFit.contain,
            gaplessPlayback: true,
          ),
        );
      }
      final String? net = _netUrl;
      if (net != null) {
        return SizedBox.expand(
          child: Image.network(
            net,
            fit: BoxFit.contain,
            gaplessPlayback: true,
            errorBuilder: (
              BuildContext context,
              Object error,
              StackTrace? stackTrace,
            ) {
              return const Center(
                child: Text(
                  'Live camera offline',
                  style: TextStyle(color: Color(0xFF9A8F88), fontSize: 12),
                ),
              );
            },
          ),
        );
      }
      return const Center(
        child: Text(
          'Connecting camera…',
          style: TextStyle(color: Color(0xFF9A8F88), fontSize: 12),
        ),
      );
    }
    return HtmlElementView(viewType: _viewType);
  }
}
