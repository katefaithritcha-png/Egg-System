import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

class LiveCamMjpeg extends StatefulWidget {
  const LiveCamMjpeg({
    super.key,
    required this.streamUrl,
    this.pollSnapshots = false,
  });

  final String streamUrl;

  /// Worker dashboard refreshes single JPEGs from /live.jpg.
  final bool pollSnapshots;

  @override
  State<LiveCamMjpeg> createState() => _LiveCamMjpegState();
}

class _LiveCamMjpegState extends State<LiveCamMjpeg> {
  HttpClient? _client;
  Uint8List? _jpg;
  bool _run = true;
  int _lastPaintUs = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_read());
  }

  @override
  void didUpdateWidget(LiveCamMjpeg oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.streamUrl != widget.streamUrl) {
      _client?.close(force: true);
    }
  }

  @override
  void dispose() {
    _run = false;
    _client?.close(force: true);
    super.dispose();
  }

  int _find(Uint8List data, int a, int b, [int from = 0]) {
    for (var i = from; i < data.length - 1; i++) {
      if (data[i] == a && data[i + 1] == b) return i;
    }
    return -1;
  }

  String get _snapshotUrl {
    final String base = widget.streamUrl.replaceFirst(
      RegExp(r'/stream/?$'),
      '/live.jpg',
    );
    return '$base?t=${DateTime.now().millisecondsSinceEpoch}';
  }

  Future<void> _readSnapshots() async {
    while (_run && mounted) {
      final HttpClient client = HttpClient();
      _client = client;
      try {
        final HttpClientRequest req = await client.getUrl(Uri.parse(_snapshotUrl));
        final HttpClientResponse res = await req.close().timeout(
          const Duration(seconds: 4),
        );
        final BytesBuilder builder = BytesBuilder(copy: false);
        await for (final List<int> chunk in res) {
          if (!_run || !mounted) break;
          builder.add(chunk);
        }
        final Uint8List jpg = builder.takeBytes();
        if (res.statusCode == 200 &&
            jpg.length > 2 &&
            jpg[0] == 0xFF &&
            jpg[1] == 0xD8 &&
            mounted) {
          setState(() => _jpg = jpg);
        }
      } catch (_) {
        // Keep the last good frame and try again.
      } finally {
        client.close(force: true);
      }
      // 50–200 ms live refresh for smooth egg motion on native.
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  Future<void> _read() async {
    if (widget.pollSnapshots) {
      await _readSnapshots();
      return;
    }
    var buf = Uint8List(0);
    while (_run && mounted) {
      final HttpClient client = HttpClient();
      _client = client;
      try {
        final Uri uri = Uri.parse(widget.streamUrl);
        final HttpClientRequest req = await client.getUrl(uri);
        final HttpClientResponse res = await req.close().timeout(
          const Duration(seconds: 8),
        );
        await for (final List<int> chunk in res) {
          if (!_run || !mounted) break;
          final Uint8List next = Uint8List(buf.length + chunk.length);
          next.setAll(0, buf);
          next.setAll(buf.length, chunk);
          buf = next;
          while (true) {
            final int start = _find(buf, 0xFF, 0xD8);
            if (start < 0) {
              if (buf.length > 200000) {
                buf = buf.sublist(buf.length - 100000);
              }
              break;
            }
            final int end = _find(buf, 0xFF, 0xD9, start + 2);
            if (end < 0) {
              if (start > 0) buf = buf.sublist(start);
              break;
            }
            final Uint8List jpg = Uint8List.fromList(buf.sublist(start, end + 2));
            buf = buf.sublist(end + 2);
            final int now = DateTime.now().microsecondsSinceEpoch;
            // Cap paint to ~50 ms (20 fps) — smoother than 33 ms decode spam.
            if (now - _lastPaintUs < 50000) continue;
            _lastPaintUs = now;
            if (mounted) setState(() => _jpg = jpg);
          }
        }
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      } finally {
        client.close(force: true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
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
}
