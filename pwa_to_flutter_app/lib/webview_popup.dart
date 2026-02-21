import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'constants.dart';
import 'util.dart';

class WebViewPopup extends StatelessWidget {
  final CreateWindowAction createWindowAction;
  final InAppWebViewSettings popupWebViewSettings;

  const WebViewPopup(
      {super.key,
      required this.createWindowAction,
      required this.popupWebViewSettings});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<bool>(
        future: isNetworkAvailable(),
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return Container();
          }

          final bool networkAvailable = snapshot.data ?? false;

          // Android-only
          final cacheMode = networkAvailable
              ? CacheMode.LOAD_DEFAULT
              : CacheMode.LOAD_CACHE_ELSE_NETWORK;

          final webViewInitialSettings = popupWebViewSettings.copy();
          webViewInitialSettings.cacheMode = cacheMode;

          return AlertDialog(
            content: SizedBox(
              width: double.maxFinite,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    height: 250,
                    child: InAppWebView(
                      gestureRecognizers: <
                          Factory<OneSequenceGestureRecognizer>>{
                        Factory<OneSequenceGestureRecognizer>(
                          () => EagerGestureRecognizer(),
                        ),
                      },
                      initialSettings: webViewInitialSettings,
                      windowId: createWindowAction.windowId,
                      onPermissionRequest: (controller, request) async {
                        // السماح تلقائياً للموقع الموثوق
                        if (request.origin.host == 'driver.zoonasd.com') {
                          return PermissionResponse(
                            resources: request.resources,
                            action: PermissionResponseAction.GRANT,
                          );
                        }

                        // للمواقع الأخرى، نطلب إذن المستخدم
                        bool granted = await showDialog<bool>(
                              context: context,
                              builder: (context) => AlertDialog(
                                title: const Text('طلب إذن'),
                                content: Text(
                                    'يرغب الموقع ${request.origin} في الوصول إلى: ${request.resources.join(", ")}'),
                                actions: [
                                  TextButton(
                                    onPressed: () =>
                                        Navigator.pop(context, false),
                                    child: const Text('رفض'),
                                  ),
                                  TextButton(
                                    onPressed: () =>
                                        Navigator.pop(context, true),
                                    child: const Text('سماح'),
                                  ),
                                ],
                              ),
                            ) ??
                            false;

                        return PermissionResponse(
                          resources: request.resources,
                          action: granted
                              ? PermissionResponseAction.GRANT
                              : PermissionResponseAction.DENY,
                        );
                      },
                      onCloseWindow: (controller) {
                        Navigator.pop(context);
                      },
                      onReceivedError: (controller, request, error) async {
                        final isForMainFrame = request.isForMainFrame ?? true;
                        if (isForMainFrame && !(await isNetworkAvailable())) {
                          if (!(await isPWAInstalled())) {
                            await controller.loadData(
                                data: kHTMLErrorPageNotInstalled);
                          } else if (request.url.host != kPwaHost) {
                            await controller.loadData(data: kHTMLErrorPage);
                          }
                        }
                      },
                    ),
                  ),
                ],
              ),
            ),
          );
        });
  }
}
