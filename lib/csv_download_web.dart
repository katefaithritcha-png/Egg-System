import 'dart:html' as html;

void downloadTextFile(
  String fileName,
  String contents, {
  String mimeType = 'text/csv',
}) {
  final html.Blob blob = html.Blob(<Object>[contents], mimeType);
  final String url = html.Url.createObjectUrlFromBlob(blob);
  html.AnchorElement(href: url)
    ..setAttribute('download', fileName)
    ..click();
  html.Url.revokeObjectUrl(url);
}
