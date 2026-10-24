import 'dart:async';
import 'dart:html' as html;
import 'dart:typed_data';
import 'dart:ui_web' as ui_web;

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

class LiveCamMjpeg extends StatefulWidget {
  const LiveCamMjpeg({
    super.key,
    required this.streamUrl,
    this.pollSnapshots = false,
  });

  final String streamUrl;

  /// Worker dashboard: refresh /live.jpg. The multipart /stream stays blank
  /// inside a Flutter web view when frames arrive slower than the browser paint.
  final bool pollSnapshots;

  @override
  State<LiveCamMjpeg> createState() => _LiveCamMjpegState();
}

class _LiveCamMjpegState extends State<LiveCamMjpeg> {
  late final String _viewType;
  html.ImageElement? _image;
  Uint8List? _jpg;
  bool _run = true;

  String get _snapshotUrl {
    final String base = widget.streamUrl.replaceFirst(
      RegExp(r'/stream/?$'),
      '/live.jpg',
    );
    return '$base?t=${DateTime.now().millisecondsSinceEpoch}';
  }

  void _paintStream() {
    final html.ImageElement? image = _image;
    if (image == null) {
      return;
    }
    image.src = widget.streamUrl;
  }

  Future<void> _pollSnapshots() async {
    while (_run && mounted && widget.pollSnapshots) {
      try {
        final http.Response res = await http
            .get(Uri.parse(_snapshotUrl))
            .timeout(const Duration(seconds: 4));
        final Uint8List jpg = res.bodyBytes;
        if (res.statusCode == 200 &&
            jpg.length > 2 &&
            jpg[0] == 0xFF &&
            jpg[1] == 0xD8 &&
            mounted) {
          setState(() => _jpg = jpg);
        }
      } catch (_) {
        // Keep the last good frame and try again.
      }
      await Future<void>.delayed(const Duration(milliseconds: 350));
    }
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
      if (jpg == null) {
        return const Center(
          child: Text(
            'Live camera offline',
            style: TextStyle(color: Color(0xFF9A8F88), fontSize: 12),
          ),
        );
      }
      return SizedBox.expand(
        child: Image.memory(
          jpg,
          fit: BoxFit.contain,
          gaplessPlayback: true,
        ),
      );
    }
    return HtmlElementView(viewType: _viewType);
  }
}
