import 'package:url_launcher/url_launcher.dart';

/// Opens [url] in an external browser on non-web platforms.
Future<void> openUrlInBrowser(String url) async {
  await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
}
