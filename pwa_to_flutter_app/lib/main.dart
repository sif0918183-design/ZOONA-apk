import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:onesignal_flutter/onesignal_flutter.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:vibration/vibration.dart';

import 'webview_popup.dart';
import 'util.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // --- تهيئة OneSignal للإصدار 5.x ---
  OneSignal.onesignal.setAppId("c05c5d16-4e72-4d4a-b1a2-6e7e06232d98");

  // طلب إذن الإشعارات (Android يقبل تلقائياً)
  await OneSignal.onesignal.promptUserForPushNotificationPermission();

  if (!kIsWeb && kDebugMode && defaultTargetPlatform == TargetPlatform.android) {
    await InAppWebViewController.setWebContentsDebuggingEnabled(kDebugMode);
  }

  runApp(const MaterialApp(
    debugShowCheckedModeBanner: false,
    home: MyApp(),
  ));
}

class MyApp extends StatefulWidget {
  const MyApp({Key? key}) : super(key: key);
  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> with WidgetsBindingObserver {
  final GlobalKey webViewKey = GlobalKey();
  InAppWebViewController? webViewController;

  final AudioPlayer audioPlayer = AudioPlayer();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    setupOneSignalListeners();
  }

  void setupOneSignalListeners() {
    // عرض الإشعار في الواجهة الأمامية
    OneSignal.onesignal.setNotificationWillShowInForegroundHandler((event) {
      event.complete(event.notification);
    });

    // عند فتح الإشعار
    OneSignal.onesignal.setNotificationOpenedHandler((openedResult) async {
      // --- تشغيل الصوت ---
      try {
        await audioPlayer.play(AssetSource('ride_request_sound.wav'));
      } catch (e) {
        debugPrint("Error playing sound: $e");
      }

      // --- الاهتزاز ---
      if (await Vibration.hasVibrator() ?? false) {
        Vibration.vibrate(pattern: [500, 200, 500, 200, 500, 200], repeat: 1);
      }

      // --- فتح رابط قبول الرحلة ---
      final data = openedResult.notification.additionalData;
      final rideId = data?['rideId']?.toString() ?? "";
      final requestId = data?['requestId']?.toString() ?? "";

      String acceptUrl =
          "https://driver.zoonasd.com/accept-ride.html?rideId=$rideId&requestId=$requestId";

      webViewController?.loadUrl(urlRequest: URLRequest(url: WebUri(acceptUrl)));
    });
  }

  InAppWebViewSettings sharedSettings = InAppWebViewSettings(
    supportMultipleWindows: true,
    javaScriptCanOpenWindowsAutomatically: true,
    applicationNameForUserAgent: 'Tirhal Driver App',
    userAgent:
        'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/119.0.0.0 Mobile Safari/537.36',
    disableDefaultErrorPage: true,
    allowsInlineMediaPlayback: true,
    mediaPlaybackRequiresUserGesture: false,
    limitsNavigationsToAppBoundDomains: true,
  );

  @override
  void dispose() {
    webViewController = null;
    audioPlayer.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!kIsWeb && webViewController != null && defaultTargetPlatform == TargetPlatform.android) {
      if (state == AppLifecycleState.paused) {
        webViewController?.pause();
        webViewController?.pauseTimers();
      } else if (state == AppLifecycleState.resumed) {
        webViewController?.resume();
        webViewController?.resumeTimers();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvoked: (didPop) async {
        if (didPop) return;
        final controller = webViewController;
        if (controller != null && await controller.canGoBack()) {
          controller.goBack();
        }
      },
      child: Scaffold(
        appBar: AppBar(toolbarHeight: 0, backgroundColor: Colors.black),
        body: Column(
          children: <Widget>[
            Expanded(
              child: FutureBuilder<bool>(
                future: isNetworkAvailable(),
                builder: (context, snapshot) {
                  if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());

                  final networkAvailable = snapshot.data ?? false;
                  final webViewInitialSettings = sharedSettings.copy();
                  webViewInitialSettings.cacheMode =
                      networkAvailable ? CacheMode.LOAD_DEFAULT : CacheMode.LOAD_CACHE_ELSE_NETWORK;

                  return InAppWebView(
                    key: webViewKey,
                    initialUrlRequest: URLRequest(url: WebUri("https://driver.zoonasd.com/")),
                    initialSettings: webViewInitialSettings,
                    onWebViewCreated: (controller) {
                      webViewController = controller;
                    },
                    onLoadStop: (controller, url) async {
                      if (url != null && url.queryParameters.containsKey('driver_id')) {
                        String? driverId = url.queryParameters['driver_id'];
                        if (driverId != null && driverId.isNotEmpty) {
                          OneSignal.onesignal.setExternalUserId(driverId);
                          debugPrint("OneSignal: Device linked to Driver ID: $driverId");
                        }
                      }
                    },
                    shouldOverrideUrlLoading: (controller, navigationAction) async {
                      final uri = navigationAction.request.url;
                      if (uri != null &&
                          navigationAction.isForMainFrame &&
                          uri.host != "driver.zoonasd.com" &&
                          await canLaunchUrl(uri)) {
                        launchUrl(uri, mode: LaunchMode.externalApplication);
                        return NavigationActionPolicy.CANCEL;
                      }
                      return NavigationActionPolicy.ALLOW;
                    },
                    onCreateWindow: (controller, createWindowAction) async {
                      showDialog(
                        context: context,
                        builder: (context) {
                          final popupWebViewSettings = sharedSettings.copy();
                          popupWebViewSettings.supportMultipleWindows = false;
                          return WebViewPopup(
                              createWindowAction: createWindowAction,
                              popupWebViewSettings: popupWebViewSettings);
                        },
                      );
                      return true;
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}