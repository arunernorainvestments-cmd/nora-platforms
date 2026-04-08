// Conditional export: uses dart:html on web (guarantees _blank target and avoids
// popup-blocker fallback to same-tab navigation), url_launcher on other platforms.
export 'open_url_stub.dart'
    if (dart.library.html) 'open_url_web.dart';
