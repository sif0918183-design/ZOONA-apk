import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:onesignal_flutter/onesignal_flutter.dart';
import 'package:audioplayers/audioplayers.dart'; // مكتبة الصوت
import 'package:vibration/vibration.dart';      // مكتبة الاهتزاز

import 'webview_popup.dart';
import 'util.dart'; 

Future main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // 1. إعداد OneSignal
  OneSignal.Debug.setLogLevel(OSLogLevel.verbose);
  OneSignal.initialize("e542557c-fbed-4ca6-96fa-0b37e0d21490");
  
  // طلب إذن الإشعارات
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
  
  // تعريف مشغل الصوت كمتغير دائم
  final AudioPlayer audioPlayer = AudioPlayer();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    setupOneSignalListeners();
  }

  // 2. إدارة التفاعل مع الإشعارات + الصوت + الاهتزاز
  void setupOneSignalListeners() {
    // الاستماع للإشعارات عند النقر عليها (في الخلفية)
    OneSignal.Notifications.addClickListener((event) {
      _handleRideNotification(event.notification);
    });

    // الاستماع للإشعارات أثناء فتح التطبيق (في المقدمة)
    OneSignal.Notifications.addForegroundWillDisplayListener((event) {
      // منع ظهور الإشعار الافتراضي واستخدام نافذتنا الخاصة بدلاً منه
      event.preventDefault();
      _handleRideNotification(event.notification);
    });
  }

  // معالج موحد لطلبات الرحلة
  void _handleRideNotification(OSNotification notification) async {
    final data = notification.additionalData;
    if (data == null) return;

    final String rideId = data['rideId']?.toString() ?? "";
    final String requestId = data['requestId']?.toString() ?? "";

    if (rideId.isEmpty) return;

    // 1. تشغيل صوت الرنين بشكل متكرر
    try {
      await audioPlayer.setReleaseMode(ReleaseMode.loop);
      await audioPlayer.play(AssetSource('ride_request_sound.wav'));
    } catch (e) {
      debugPrint("Error playing sound: $e");
    }

    // 2. تشغيل الاهتزاز بنمط متكرر
    if (await Vibration.hasVibrator() ?? false) {
      Vibration.vibrate(pattern: [500, 1000, 500, 1000], repeat: 0);
    }

    // 3. إظهار نافذة طلب الرحلة في وسط الشاشة
    if (!mounted) return;

    showDialog(
      context: context,
      barrierDismissible: false, // يجب على السائق الاستجابة
      builder: (context) {
        String acceptUrl = "https://driver.zoonasd.com/accept-ride.html?rideId=$rideId&requestId=$requestId";

        return AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          contentPadding: EdgeInsets.zero,
          content: Container(
            width: double.maxFinite,
            height: 500, // ارتفاع مناسب لنافذة الطلب
            child: ClipRRect(
              borderRadius: BorderRadius.circular(20),
              child: InAppWebView(
                initialUrlRequest: URLRequest(url: WebUri(acceptUrl)),
                initialSettings: sharedSettings,
                onWebViewCreated: (controller) {
                  // إضافة معالج لإغلاق النافذة من داخل الويب
                  controller.addJavaScriptHandler(handlerName: 'closeRideDialog', callback: (args) {
                    Navigator.of(context).pop();
                  });
                },
                onCloseWindow: (controller) {
                  Navigator.of(context).pop();
                },
              ),
            ),
          ),
        );
      },
    ).then((_) {
      // عند إغلاق النافذة (سواء بالقبول أو الرفض أو الإلغاء)
      audioPlayer.stop();
      Vibration.cancel();
    });
  }

  InAppWebViewSettings sharedSettings = InAppWebViewSettings(
      supportMultipleWindows: true,
      javaScriptCanOpenWindowsAutomatically: true,
      applicationNameForUserAgent: 'Tirhal Driver App',
      userAgent: 'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/119.0.0.0 Mobile Safari/537.36',
      disableDefaultErrorPage: true,
      allowsInlineMediaPlayback: true, 
      mediaPlaybackRequiresUserGesture: false, // تسمح بتشغيل الوسائط تلقائياً بعد تفاعل المستخدم مع التطبيق
      limitsNavigationsToAppBoundDomains: true);

  @override
  void dispose() {
    webViewController = null;
    audioPlayer.dispose(); // إغلاق مشغل الصوت عند إغلاق التطبيق
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
    // استخدمنا PopScope بدلاً من WillPopScope لأنها الأحدث في إصدارات Flutter الجديدة
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
                    onLoadStop: (controller, url) async {
                      if (url != null && url.queryParameters.containsKey('driver_id')) {
                        String? driverId = url.queryParameters['driver_id'];
                        if (driverId != null && driverId.isNotEmpty) {
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
