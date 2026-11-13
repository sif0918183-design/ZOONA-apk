import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:url_launcher/url_launcher.dart';

// PWA Url
final kPwaUri = WebUri('https://zoonasd.com/');
final kPwaHost = kPwaUri.host;

// Hosts that must always stay inside the WebView (auth/payment exceptions).
// Kept empty by default: Zoona auth/payment flows run on the internal domain.
const kTrustedInternalHosts = <String>[];

/// Hosts inside the Zoona domain that must still open in the external browser
/// (e.g. Tracka). Matched exactly, so no other subdomain is affected.
const kExternalHosts = <String>{'tracka.zoonasd.com'};

/// App-handler schemes that are always forwarded to their native app.
const _kAppSchemes = <String>{'whatsapp', 'tel', 'sms', 'mailto'};

/// Hosts that belong to WhatsApp and are forwarded to the WhatsApp app.
const _kWhatsAppHosts = <String>{'wa.me', 'api.whatsapp.com'};

/// Returns `true` when [host] is the Zoona domain or one of its subdomains.
/// Comparison is done on the parsed host, never on the raw URL string, so
/// look-alike domains such as `zoonasd.com.example.com` are rejected.
bool isInternalHost(String host) {
  final h = host.toLowerCase();
  return h == kPwaHost || h.endsWith('.$kPwaHost');
}

bool _isAppHandlerUri(WebUri uri) {
  final scheme = uri.scheme.toLowerCase();
  return _kAppSchemes.contains(scheme) || _kWhatsAppHosts.contains(uri.host);
}

/// Opens [uri] in the native app that handles it (browser or app handler).
Future<void> launchExternalUrl(WebUri uri) async {
  try {
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (_) {}
}

/// Returns `true` when [uri] must be handled outside the WebView, launching the
/// matching native app/browser as a side effect. Returns `false` for internal
/// Zoona hosts and for schemes the WebView should handle itself.
Future<bool> shouldOpenExternally(WebUri uri) async {
  if (_isAppHandlerUri(uri)) {
    await launchExternalUrl(uri);
    return true;
  }

  final scheme = uri.scheme.toLowerCase();
  if (scheme == 'http' || scheme == 'https') {
    final forcedExternal = kExternalHosts.contains(uri.host.toLowerCase());
    if (!forcedExternal &&
        (isInternalHost(uri.host) || kTrustedInternalHosts.contains(uri.host))) {
      return false;
    }
    await launchExternalUrl(uri);
    return true;
  }

  return false;
}

/// Shared navigation policy applied by every WebView (main and popup).
///
/// - App-handler schemes (WhatsApp, tel, sms, mailto) -> external app.
/// - HTTP/HTTPS on the Zoona domain or trusted hosts -> stay in the WebView.
/// - Any other HTTP/HTTPS -> external browser.
/// - Everything else -> default WebView behaviour.
Future<NavigationActionPolicy> applyUrlPolicy(
    NavigationAction navigationAction) async {
  if (!navigationAction.isForMainFrame) {
    return NavigationActionPolicy.ALLOW;
  }

  final uri = navigationAction.request.url;
  if (uri == null) return NavigationActionPolicy.ALLOW;

  if (await shouldOpenExternally(uri)) {
    return NavigationActionPolicy.CANCEL;
  }

  return NavigationActionPolicy.ALLOW;
}

// Custom HTML Error Page.
const kHTMLErrorPage = """
<html>
  <head></head> 
  <body>
    <h1>Not connected to Internet :(</h1>
  </body>
</html>
""";

// Custom HTML Error Page if the App has not been installed correctly the first time.
const kHTMLErrorPageNotInstalled = """
<html>
  <head></head>
  <body>
    <h1>You must be connected to Internet at least one time to install correctly the App.</h1>
  </body>
</html>
""";