import 'csv_download_stub.dart'
    if (dart.library.html) 'csv_download_web.dart' as impl;

/// Triggers a browser file download on web; no-op on other platforms.
void downloadTextFile(
  String fileName,
  String contents, {
  String mimeType = 'text/csv',
}) {
  impl.downloadTextFile(fileName, contents, mimeType: mimeType);
}
