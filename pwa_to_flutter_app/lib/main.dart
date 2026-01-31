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
import 'package:connectivity_plus/connectivity_plus.dart';
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
  // تفعيل سجلات التصحيح لرؤية عملية الربط في الـ Console
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

  bool _isLoading = true;
  String _currentUrl = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initApp();
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
    // معالج استقبال الإشعار والتطبيق مفتوح
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
      theme: ThemeData(primarySwatch: Colors.blue),
      home: Scaffold(
        body: SafeArea(
          child: Stack(
            children: [
              _buildWebView(),
              if (_isLoading)
                const Center(child: CircularProgressIndicator()),
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
        domStorageEnabled: true, // ضروري لقراءة localStorage
        supportZoom: false,
      ),
      pullToRefreshController: pullToRefreshController,
      onWebViewCreated: (controller) {
        webViewController = controller;
      },
      onLoadStart: (_, __) {
        setState(() => _isLoading = true);
      },
      onLoadStop: (controller, url) async {
        setState(() => _isLoading = false);
        pullToRefreshController?.endRefreshing();

        // --- الخطوة الجوهرية: الربط مع OneSignal ---
        await _syncUserIdWithOneSignal(controller, url);
      },
    );
  }

  /// وظيفة لمزامنة معرف السائق بين الموقع و OneSignal
  Future<void> _syncUserIdWithOneSignal(InAppWebViewController controller, WebUri? url) async {
    try {
      String? driverId;

      // 1. المحاولة الأولى: القراءة من localStorage (كما اقترحت أنت)
      final String? storageId = await controller.evaluateJavascript(
          source: "localStorage.getItem('driver_id');"
      );
      
      if (storageId != null && storageId != "null" && storageId.isNotEmpty) {
        driverId = storageId.replaceAll('"', ''); // تنظيف القيمة من علامات الاقتباس
      } 
      // 2. المحاولة الثانية: القراءة من الرابط (URL) كاحتياطي
      else if (url != null && url.queryParameters.containsKey('driver_id')) {
        driverId = url.queryParameters['driver_id'];
      }

      // 3. إذا وجدنا المعرف، نقوم بعملية الربط
      if (driverId != null && driverId.isNotEmpty) {
        await OneSignal.shared.setExternalUserId(driverId);
        
        // حفظه محلياً في ذاكرة الهاتف للتأكد
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('synced_driver_id', driverId);
        
        print("✅ Success: Linked OneSignal to Driver ID: $driverId");
      }
    } catch (e) {
      print("❌ Error during OneSignal sync: $e");
    }
  }
}
