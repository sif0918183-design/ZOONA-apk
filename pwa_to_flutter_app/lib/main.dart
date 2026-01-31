import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:onesignal_flutter/onesignal_flutter.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:vibration/vibration.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await initializeOneSignal();

  if (Platform.isAndroid) {
    await InAppWebViewController.setWebContentsDebuggingEnabled(kDebugMode);
  }

  runApp(const MyApp());
}

Future<void> initializeOneSignal() async {
  // تفعيل السجلات لتتبع عملية الربط في الـ Console
  OneSignal.shared.setLogLevel(OSLogLevel.verbose, OSLogLevel.none);
  
  await OneSignal.shared.setAppId(
    "c05c5d16-4e72-4d4a-b1a2-6e7e06232d98",
  );

  await OneSignal.shared.promptUserForPushNotificationPermission();
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
  PullToRefreshController? pullToRefreshController;
  
  // مؤقت لمراقبة تسجيل الدخول في localStorage
  Timer? _authPollingTimer;

  bool _isLoading = true;
  String _currentUrl = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initApp();
  }

  @override
  void dispose() {
    _authPollingTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _initApp() async {
    await _setupOneSignalListeners();

    pullToRefreshController = PullToRefreshController(
      settings: PullToRefreshSettings(color: Colors.blue),
      onRefresh: () async {
        await webViewController?.reload();
      },
    );

    await audioPlayer.setSource(
      AssetSource('ride_request_sound.wav'),
    );
  }

  Future<void> _setupOneSignalListeners() async {
    // معالج وصول الإشعار والتطبيق مفتوح
    OneSignal.shared.setNotificationWillShowInForegroundHandler((event) async {
      await _playNotificationSound();
      await _vibrateDevice();
      event.complete(event.notification);
    });

    // معالج الضغط على الإشعار
    OneSignal.shared.setNotificationOpenedHandler((openedResult) async {
      final data = openedResult.notification.additionalData ?? {};
      final rideId = data['rideId']?.toString() ?? '';
      final requestId = data['requestId']?.toString() ?? '';

      if (rideId.isNotEmpty && requestId.isNotEmpty) {
        final url = "https://driver.zoonasd.com/accept-ride.html?rideId=$rideId&requestId=$requestId";
        _loadRideUrl(url);
      }
    });
  }

  Future<void> _playNotificationSound() async {
    try {
      await audioPlayer.stop();
      await audioPlayer.play(AssetSource('ride_request_sound.wav'));
    } catch (e) {
      print("Error playing sound: $e");
    }
  }

  Future<void> _vibrateDevice() async {
    if (await Vibration.hasVibrator() ?? false) {
      await Vibration.vibrate(pattern: [500, 250, 500]);
    }
  }

  void _loadRideUrl(String url) {
    if (webViewController != null) {
      webViewController!.loadUrl(urlRequest: URLRequest(url: WebUri(url)));
    } else {
      _currentUrl = url;
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'ترحال زونا - السائق',
      theme: ThemeData(primarySwatch: Colors.green),
      home: Scaffold(
        body: SafeArea(
          child: Stack(
            children: [
              _buildWebView(),
              if (_isLoading)
                const Center(child: CircularProgressIndicator(color: Colors.green)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildWebView() {
    return InAppWebView(
      key: webViewKey,
      initialUrlRequest: URLRequest(
        url: WebUri(_currentUrl.isNotEmpty ? _currentUrl : "https://driver.zoonasd.com/"),
      ),
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        useHybridComposition: true,
        domStorageEnabled: true, // تفعيل الوصول لـ localStorage
        supportZoom: false,
      ),
      pullToRefreshController: pullToRefreshController,
      onWebViewCreated: (controller) {
        webViewController = controller;
      },
      onLoadStart: (_, __) {
        setState(() => _isLoading = true);
        _authPollingTimer?.cancel(); // إيقاف المؤقت القديم عند بدء تحميل صفحة جديدة
      },
      onLoadStop: (controller, url) async {
        setState(() => _isLoading = false);
        pullToRefreshController?.endRefreshing();

        // بدء مراقبة الـ localStorage بمجرد انتهاء تحميل الصفحة
        _startAuthPolling(controller);
      },
    );
  }

  /// وظيفة المراقبة الدورية للـ localStorage
  void _startAuthPolling(InAppWebViewController controller) {
    _authPollingTimer?.cancel(); // التأكد من عدم وجود مؤقتات مكررة
    
    _authPollingTimer = Timer.periodic(const Duration(seconds: 2), (timer) async {
      try {
        // قراءة قيمة driver_id من متصفح الـ WebView
        final dynamic result = await controller.evaluateJavascript(
            source: "localStorage.getItem('driver_id');"
        );

        if (result != null && result != "null" && result.toString().isNotEmpty) {
          String driverId = result.toString().replaceAll('"', ''); // تنظيف القيمة من الاقتباسات
          
          // ربط المعرف بـ OneSignal
          await OneSignal.shared.setExternalUserId(driverId);
          
          print("🎯 [Sync Success] Driver ID $driverId found in LocalStorage and linked to OneSignal.");

          // حفظ المعرف في Shared Preferences كنسخة احتياطية دائمة في الهاتف
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString('synced_driver_id', driverId);

          // إيقاف المراقبة لأننا وجدنا المعرف ونجح الربط
          timer.cancel();
        } else {
          // لم يجد المعرف بعد (ربما السائق لم يسجل دخوله بعد)
          if (kDebugMode) print("⏳ [Sync Waiting] driver_id not found yet in localStorage...");
        }
      } catch (e) {
        if (kDebugMode) print("⚠️ [Sync Error] Error polling localStorage: $e");
      }
    });
  }
}
