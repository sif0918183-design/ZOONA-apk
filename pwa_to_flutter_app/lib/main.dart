import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:onesignal_flutter/onesignal_flutter.dart';

import 'webview_popup.dart';
import 'util.dart'; // تأكد من وجود دالة isNetworkAvailable هنا

Future main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // 1. إعداد OneSignal
  // ملاحظة: يمكنك تقليل مستوى اللوج في النسخة النهائية بوضع OSLogLevel.none
  OneSignal.Debug.setLogLevel(OSLogLevel.verbose);
  OneSignal.initialize("e542557c-fbed-4ca6-96fa-0b37e0d21490");
  
  // طلب إذن الإشعارات (يظهر للمستخدم عند فتح التطبيق لأول مرة)
  OneSignal.Notifications.requestPermission(true);

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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    setupOneSignalListeners();
  }

  // 2. إدارة التفاعل مع الإشعارات (النقر على زر قبول)
  void setupOneSignalListeners() {
    OneSignal.Notifications.addClickListener((event) {
      final actionId = event.result.actionId; // الـ ID الخاص بالزر (مثل 'accept')
      final data = event.notification.additionalData;
      
      // استخراج المعرفات المرسلة من تطبيق طالب الرحلة
      final String rideId = data?['rideId']?.toString() ?? "";
      final String requestId = data?['requestId']?.toString() ?? "";

      if (actionId == "accept") {
        // توجيه الـ WebView لصفحة القبول مع تمرير البيانات في الرابط
        String acceptUrl = "https://driver.zoonasd.com/accept-ride.html?rideId=$rideId&requestId=$requestId";
        
        webViewController?.loadUrl(
          urlRequest: URLRequest(url: WebUri(acceptUrl))
        );
      }
    });
  }

  InAppWebViewSettings sharedSettings = InAppWebViewSettings(
      supportMultipleWindows: true,
      javaScriptCanOpenWindowsAutomatically: true,
      applicationNameForUserAgent: 'Tirhal Driver App',
      // UserAgent حديث لضمان توافق الموقع والـ PWA
      userAgent: 'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/119.0.0.0 Mobile Safari/537.36',
      disableDefaultErrorPage: true,
      allowsInlineMediaPlayback: true, // مهم جداً لتشغيل صوت التنبيه داخل المتصفح
      limitsNavigationsToAppBoundDomains: true);

  @override
  void dispose() {
    webViewController = null;
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
    return WillPopScope(
      onWillPop: () async {
        final controller = webViewController;
        if (controller != null && await controller.canGoBack()) {
          controller.goBack();
          return false;
        }
        return true;
      },
      child: Scaffold(
          appBar: AppBar(toolbarHeight: 0, backgroundColor: Colors.black),
          body: Column(children: <Widget>[
            Expanded(
              child: FutureBuilder<bool>(
                future: isNetworkAvailable(),
                builder: (context, snapshot) {
                  if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
                  
                  final bool networkAvailable = snapshot.data ?? false;
                  final webViewInitialSettings = sharedSettings.copy();
                  webViewInitialSettings.cacheMode = networkAvailable 
                      ? CacheMode.LOAD_DEFAULT 
                      : CacheMode.LOAD_CACHE_ELSE_NETWORK;

                  return InAppWebView(
                    key: webViewKey,
                    initialUrlRequest: URLRequest(url: WebUri("https://driver.zoonasd.com/")),
                    initialSettings: webViewInitialSettings,
                    onWebViewCreated: (controller) {
                      webViewController = controller;
                    },
                    // 3. الربط السحري: مراقبة الروابط لتسجيل دخول السائق في OneSignal
                    onLoadStop: (controller, url) async {
                      if (url != null && url.queryParameters.containsKey('driver_id')) {
                        String? driverId = url.queryParameters['driver_id'];
                        if (driverId != null && driverId.isNotEmpty) {
                          // تسجيل المعرف في OneSignal لربط هذا الجهاز بهذا السائق
                          OneSignal.login(driverId);
                          debugPrint("OneSignal: Device linked to Driver ID: $driverId");
                        }
                      }
                    },
                    shouldOverrideUrlLoading: (controller, navigationAction) async {
                      final uri = navigationAction.request.url;
                      if (uri != null && navigationAction.isForMainFrame && 
                          uri.host != "driver.zoonasd.com" && await canLaunchUrl(uri)) {
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
          ])),
    );
  }
}
