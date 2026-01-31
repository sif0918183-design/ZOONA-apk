import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
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

    // محاولة استعادة driver_id من SharedPreferences
    _restoreDriverId();
  }

  Future<void> _restoreDriverId() async {
    final prefs = await SharedPreferences.getInstance();
    final savedDriverId = prefs.getString('synced_driver_id');

    if (savedDriverId != null && savedDriverId.isNotEmpty) {
      print("🔄 [Restore] Found saved driver_id: $savedDriverId");

      // محاولة الربط مع OneSignal مباشرة
      try {
        await OneSignal.shared.setExternalUserId(savedDriverId);
        print("✅ [Restore] Linked from cache successfully");
      } catch (e) {
        print("⚠️ [Restore Error] Failed to link: $e");
      }
    }
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
    // تفعيل السجلات
    OneSignal.shared.setLogLevel(OSLogLevel.verbose, OSLogLevel.none);

    // التأكد من تهيئة OneSignal
    await OneSignal.shared.setAppId("c05c5d16-4e72-4d4a-b1a2-6e7e06232d98");

    // إضافة معالج للإشعارات
    OneSignal.shared.setNotificationWillShowInForegroundHandler((event) async {
      print("📱 Notification received in foreground: ${event.notification}");

      // تشغيل الصوت والاهتزاز
      await _playNotificationSound();
      await _vibrateDevice();

      event.complete(event.notification);
    });

    // معالج فتح الإشعار
    OneSignal.shared.setNotificationOpenedHandler((openedResult) async {
      print("📱 Notification opened: ${openedResult.notification}");

      final data = openedResult.notification.additionalData ?? {};
      final rideId = data['rideId']?.toString() ?? '';
      final requestId = data['requestId']?.toString() ?? '';

      if (rideId.isNotEmpty && requestId.isNotEmpty) {
        final url = "https://driver.zoonasd.com/accept-ride.html?rideId=$rideId&requestId=$requestId";
        _loadRideUrl(url);
      }
    });

    // الحصول على playerId وتخزينه
    final playerId = await OneSignal.shared.getDeviceState();
    print("📱 OneSignal Player ID: ${playerId?.userId}");
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
    // Note: vibration 3.1.5 returns Future<bool>, but using == true for extra safety
    if (await Vibration.hasVibrator() == true) {
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

        // بدء المراقبة بعد التأكد من تحميل الصفحة
        await Future.delayed(const Duration(seconds: 2));
        _startAuthPolling(controller);

        // حقن JavaScript للتعاون مع PWA
        await controller.evaluateJavascript(
          source: """
            // تعريف دالة للاتصال من PWA إلى Flutter
            window.driverLinkedToFlutter = function(driverId) {
              console.log('🎯 Flutter received driverId:', driverId);
              // يمكنك إضافة منطق إضافي هنا
            };

            // مراقبة تغييرات localStorage
            window.addEventListener('storage', function(e) {
              if (e.key === 'driver_id' || e.key === 'tarhal_driver_id') {
                console.log('📱 localStorage changed:', e.key, e.newValue);
              }
            });
          """
        );
      },
    );
  }

  /// وظيفة المراقبة الدورية للـ localStorage
  void _startAuthPolling(InAppWebViewController controller) {
    _authPollingTimer?.cancel();
    
    _authPollingTimer = Timer.periodic(const Duration(seconds: 3), (timer) async {
      try {
        // طريقة أفضل لقراءة localStorage
        final dynamic result = await controller.evaluateJavascript(
          source: """
            (function() {
              try {
                // المحاولة من مصادر متعددة
                let driverId = localStorage.getItem('driver_id') ||
                              localStorage.getItem('tarhal_driver_id') ||
                              new URLSearchParams(window.location.search).get('driver_id');

                // التحقق من صحة المعرف
                if (driverId && driverId.length > 5 && driverId !== "null") {
                  // تنظيف القيمة
                  driverId = driverId.toString().replace(/["']/g, '').trim();
                  return driverId;
                }
                return null;
              } catch(e) {
                return null;
              }
            })()
          """
        );

        if (result != null && result.toString().isNotEmpty && result != "null") {
          String driverId = result.toString();
          
          print("🎯 [Sync] Found driver_id: $driverId");
          
          // ربط مع OneSignal
          try {
            await OneSignal.shared.setExternalUserId(driverId);
            print("✅ [Sync] Linked to OneSignal successfully");

            // حفظ في SharedPreferences
            final prefs = await SharedPreferences.getInstance();
            await prefs.setString('synced_driver_id', driverId);

            // إرسال تأكيد للتطبيق PWA
            await controller.evaluateJavascript(
              source: """
                if (typeof window.driverLinkedToFlutter === 'function') {
                  window.driverLinkedToFlutter('$driverId');
                }
              """
            );

            // إيقاف المؤقت بعد النجاح
            timer.cancel();

            // إشعار للمستخدم
            _showLinkedNotification(controller);

          } catch (e) {
            print("⚠️ [Sync Error] OneSignal linking failed: $e");
          }
        } else {
          print("⏳ [Sync] Waiting for driver_id...");
        }
      } catch (e) {
        print("⚠️ [Sync Error] Polling error: $e");
      }
    });
  }

  void _showLinkedNotification(InAppWebViewController controller) {
    controller.evaluateJavascript(
      source: """
        if (typeof showNotification === 'function') {
          showNotification('✅ تم ربط حسابك بنظام الإشعارات بنجاح!', 'success');
        } else {
          alert('✅ تم ربط حسابك بنظام الإشعارات بنجاح!');
        }
      """
    );
  }
}
