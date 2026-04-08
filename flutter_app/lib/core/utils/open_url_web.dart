import 'package:web/web.dart' as web;

/// Opens [url] in a new browser tab.
///
/// Uses package:web window.open with '_blank' explicitly — unlike url_launcher_web
/// which uses an empty-string target that browsers can block from async contexts
/// and that may reuse an existing unnamed window instead of always opening a new tab.
Future<void> openUrlInBrowser(String url) async {
  // ignore: avoid_print
  print('[openUrlInBrowser] opening: $url');
  web.window.open(url, '_blank');
}
