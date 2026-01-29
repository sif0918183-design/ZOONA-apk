import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:onesignal_flutter/onesignal_flutter.dart';
import 'package:audioplayers/audioplayers.dart'; // مكتبة الصوت
import 'package:vibration/vibration.dart';      // مكتبة الاهتزاز

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // تهيئة OneSignal
  OneSignal.initialize("e542557c-fbed-4ca6-96fa-0b37e0d21490");
  
  // طلب إذن الإشعارات
  OneSignal.Notifications.requestPermission(true);

  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
    await InAppWebViewController.setWebContentsDebuggingEnabled(kDebugMode);
  }
  
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'ترحال زونا - السائق',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        useMaterial3: false,
      ),
      home: const MainScreen(),
    );
  }
}

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  final GlobalKey webViewKey = GlobalKey();
  InAppWebViewController? webViewController;
  bool _isLoading = true;
  
  // تعريف مشغل الصوت كمتغير دائم
  final AudioPlayer audioPlayer = AudioPlayer();

  @override
  void initState() {
    super.initState();
    _setupOneSignal();
  }

  @override
  void dispose() {
    audioPlayer.dispose();
    super.dispose();
  }

  void _setupOneSignal() {
    // مستمع الإشعارات في المقدمة
    OneSignal.Notifications.addForegroundWillDisplayListener((event) {
      // منع ظهور الإشعار الافتراضي واستخدام نافذتنا الخاصة
      event.preventDefault();
      _handleRideNotification(event.notification);
    });

    // مستمع نقر الإشعارات
    OneSignal.Notifications.addClickListener((event) {
      _handleRideNotification(event.notification);
    });
  }

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
        // استخدام الرابط المباشر من الإشعار إذا وجد، وإلا بناء الرابط الافتراضي
        String acceptUrl = data['accept_url']?.toString() ??
            "https://driver.zoonasd.com/accept-ride.html?rideId=$rideId&requestId=$requestId";

        return AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          contentPadding: EdgeInsets.zero,
          content: Container(
            width: double.maxFinite,
            height: 500,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(20),
              child: InAppWebView(
                initialUrlRequest: URLRequest(url: WebUri(acceptUrl)),
                initialSettings: InAppWebViewSettings(
                  javaScriptEnabled: true,
                  mediaPlaybackRequiresUserGesture: false,
                  supportMultipleWindows: false,
                ),
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          SafeArea(
            child: Column(
              children: [
                // شريط العنوان المخصص
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  color: const Color(0xFF4f46e5),
                  child: Row(
                    children: [
                      const Icon(Icons.directions_car, color: Colors.white),
                      const SizedBox(width: 10),
                      const Text(
                        'ترحال زونا - السائق',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const Spacer(),
                      if (_isLoading)
                        const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            color: Colors.white,
                            strokeWidth: 2,
                          ),
                        ),
                    ],
                  ),
                ),

                // WebView الرئيسي
                Expanded(
                  child: InAppWebView(
                    key: webViewKey,
                    initialUrlRequest: URLRequest(
                      url: WebUri("https://driver.zoonasd.com/"),
                    ),
                    initialSettings: InAppWebViewSettings(
                      javaScriptEnabled: true,
                      mediaPlaybackRequiresUserGesture: false,
                      supportMultipleWindows: true,
                      applicationNameForUserAgent: 'Tirhal Driver App',
                    ),
                    onWebViewCreated: (controller) {
                      webViewController = controller;

                      // إضافة معالج لربط معرف السائق يدوياً من الويب
                      controller.addJavaScriptHandler(handlerName: 'linkDriverId', callback: (args) {
                        if (args.isNotEmpty && args[0] != null) {
                          String driverId = args[0].toString();
                          OneSignal.login(driverId);
                          debugPrint("OneSignal: Device linked to Driver ID via JS Handler: $driverId");
                        }
                      });
                    },
                    onLoadStop: (controller, url) async {
                      setState(() => _isLoading = false);

                      // 1. محاولة الربط عبر URL
                      if (url != null && url.queryParameters.containsKey('driver_id')) {
                        String? driverId = url.queryParameters['driver_id'];
                        if (driverId != null && driverId.isNotEmpty) {
                          OneSignal.login(driverId);
                          debugPrint("OneSignal: Device linked to Driver ID from URL: $driverId");
                        }
                      }

                      // 2. محاولة الربط عبر localStorage
                      try {
                        String jsCode = """
                          (function() {
                            var driverData = localStorage.getItem('tarhal_driver');
                            if (driverData) {
                              var driver = JSON.parse(driverData);
                              return driver.id ? driver.id.toString() : null;
                            }
                            return null;
                          })();
                        """;
                        var result = await controller.evaluateJavascript(source: jsCode);
                        if (result != null && result is String && result.isNotEmpty) {
                          OneSignal.login(result);
                          debugPrint("OneSignal: Device linked to Driver ID from localStorage: $result");
                        }
                      } catch (e) {
                        debugPrint("Error reading driver ID from localStorage: $e");
                      }
                    },
                    shouldOverrideUrlLoading: (controller, navigationAction) async {
                      final uri = navigationAction.request.url;
                      if (uri == null) return NavigationActionPolicy.ALLOW;

                      if (uri.host == "driver.zoonasd.com") {
                        return NavigationActionPolicy.ALLOW;
                      }

                      if (await canLaunchUrl(uri)) {
                        launchUrl(uri, mode: LaunchMode.externalApplication);
                        return NavigationActionPolicy.CANCEL;
                      }

                      return NavigationActionPolicy.ALLOW;
                    },
                  ),
                ),
              ],
            ),
          ),
          if (_isLoading)
            const Center(child: CircularProgressIndicator()),
        ],
      ),
    );
  }
}
