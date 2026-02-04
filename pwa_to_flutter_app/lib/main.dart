import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:onesignal_flutter/onesignal_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:vibration/vibration.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // تهيئة Supabase
  await Supabase.initialize(
    url: 'https://zsmlyiygjagmhnglrhoa.supabase.co',
    anonKey: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InpzbWx5aXlnamFnbWhuZ2xyaG9hIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NjU5NDc3NjMsImV4cCI6MjA4MTUyMzc2M30.QviVinAng-ILq0umvI5UZCFEvNpP3nI0kW_hSaXxNps',
  );

  // تهيئة OneSignal (الإصدار 3.x)
  await OneSignal.shared.setAppId('c05c5d16-4e72-4d4a-b1a2-6e7e06232d98');
  await OneSignal.shared.setLogLevel(OSLogLevel.verbose, OSLogLevel.none);
  
  // طلب إذن الإشعارات
  await OneSignal.shared.promptUserForPushNotificationPermission(fallbackToSettings: true);

  if (Platform.isAndroid) {
    await InAppWebViewController.setWebContentsDebuggingEnabled(kDebugMode);
  }

  await _requestPermissions();
  runApp(const TarhalZoonaDriverApp());
}

Future<void> _requestPermissions() async {
  await [
    Permission.notification,
    Permission.location,
    Permission.locationAlways,
  ].request();
}

class TarhalZoonaDriverApp extends StatelessWidget {
  const TarhalZoonaDriverApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'ترحال زونا - السائق',
      theme: ThemeData(
        primaryColor: const Color(0xFF4f46e5),
        fontFamily: 'Tajawal',
        useMaterial3: true,
      ),
      home: const DriverHomeScreen(),
    );
  }
}

class DriverHomeScreen extends StatefulWidget {
  const DriverHomeScreen({super.key});

  @override
  State<DriverHomeScreen> createState() => _DriverHomeScreenState();
}

class _DriverHomeScreenState extends State<DriverHomeScreen> with WidgetsBindingObserver {
  InAppWebViewController? _webViewController;
  bool _isLoading = true;
  bool _isOnline = true;
  String? _currentDriverId;
  late final SupabaseClient _supabase;
  StreamSubscription? _connectivitySubscription;
  Timer? _statusTimer;
  Timer? _authPollingTimer;
  final AudioPlayer _audioPlayer = AudioPlayer();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _supabase = Supabase.instance.client;
    
    _setupConnectivity();
    _setupOneSignalHandlers();
    _restoreDriverId();
    
    // تحديث الحالة كل دقيقتين لضمان بقاء السائق متاحاً
    _statusTimer = Timer.periodic(const Duration(minutes: 2), (_) => _updateOnlineStatus(true));
  }

  Future<void> _restoreDriverId() async {
    final prefs = await SharedPreferences.getInstance();
    final savedId = prefs.getString('synced_driver_id');
    if (savedId != null) {
      _currentDriverId = savedId;
      await OneSignal.shared.setExternalUserId(savedId);
      debugPrint("🔄 Restored and synced driver_id: $savedId");
    }
  }

  void _setupConnectivity() {
    _connectivitySubscription = Connectivity().onConnectivityChanged.listen((result) {
      setState(() => _isOnline = result != ConnectivityResult.none);
    });
  }

  void _setupOneSignalHandlers() {
    // معالج استلام الإشعارات في المقدمة
    OneSignal.shared.setNotificationWillShowInForegroundHandler((event) async {
      debugPrint("📱 Notification received in foreground: ${event.notification.body}");

      final data = event.notification.additionalData;
      if (data != null && data['type'] == 'ride_request') {
        await _triggerAlert();
      }

      _handleIncomingNotification(data);
      event.complete(event.notification);
    });

    // معالج فتح الإشعارات
    OneSignal.shared.setNotificationOpenedHandler((openedResult) async {
      final data = openedResult.notification.additionalData;
      debugPrint("📱 Notification opened: $data");

      if (data != null) {
        final rideId = data['rideId']?.toString() ?? data['ride_id']?.toString() ?? '';
        final requestId = data['requestId']?.toString() ?? data['request_id']?.toString() ?? '';

        if (rideId.isNotEmpty) {
          final url = "https://driver.zoonasd.com/accept-ride.html?rideId=$rideId&requestId=$requestId";
          _webViewController?.loadUrl(urlRequest: URLRequest(url: WebUri(url)));
        }
      }
    });
  }

  Future<void> _triggerAlert() async {
    try {
      await Vibration.vibrate(pattern: [500, 250, 500, 250, 500], intensities: [255, 0, 255, 0, 255]);
      await _audioPlayer.play(AssetSource('ride_request_sound.wav'));
    } catch (e) {
      debugPrint("Error triggering alert: $e");
    }
  }

  Future<void> _handleIncomingNotification(Map<String, dynamic>? data) async {
    if (data != null && _webViewController != null) {
      final jsonStr = jsonEncode(data);
      await _webViewController!.evaluateJavascript(
        source: "if(window.handleRideRequest) { window.handleRideRequest($jsonStr); } else { console.log('handleRideRequest not found'); }"
      );
    }
  }

  Future<void> _updateOnlineStatus(bool online) async {
    if (_currentDriverId != null && _isOnline) {
      try {
        await _supabase.from('driver_locations').upsert({
          'driver_id': _currentDriverId,
          'is_online': online,
          'updated_at': DateTime.now().toIso8601String(),
        });
      } catch (e) {
        debugPrint("Error updating status: $e");
      }
    }
  }

  void _startAuthPolling(InAppWebViewController controller) {
    _authPollingTimer?.cancel();
    _authPollingTimer = Timer.periodic(const Duration(seconds: 3), (timer) async {
      try {
        final dynamic result = await controller.evaluateJavascript(
          source: """
            (function() {
              try {
                let id = localStorage.getItem('driver_id') || localStorage.getItem('tarhal_driver_id');
                if (id && id.length > 5 && id !== "null") {
                  return id.toString().replace(/["']/g, '').trim();
                }
                return null;
              } catch(e) { return null; }
            })()
          """
        );

        if (result != null && result.toString() != "null") {
          final String driverId = result.toString();
          if (_currentDriverId != driverId) {
            await _syncDriverWithServices(driverId);
          }
        }
      } catch (e) {
        debugPrint("Polling error: $e");
      }
    });
  }

  Future<void> _syncDriverWithServices(String driverId) async {
    _currentDriverId = driverId;

    // 1. المزامنة مع OneSignal
    await OneSignal.shared.setExternalUserId(driverId);

    // 2. الحفظ محلياً
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('synced_driver_id', driverId);

    // 3. تحديث Supabase بالتوكن
    final deviceState = await OneSignal.shared.getDeviceState();
    if (deviceState?.userId != null) {
      try {
        await _supabase.from('drivers').update({
          'push_token': deviceState!.userId,
          'last_active': DateTime.now().toIso8601String(),
        }).eq('id', driverId);
      } catch (e) {
        debugPrint("Supabase sync error: $e");
      }
    }

    _updateOnlineStatus(true);
    debugPrint("✅ Driver $driverId synced successfully");

    // إخطار الـ WebView بالنجاح
    await _webViewController?.evaluateJavascript(
      source: "if(window.showNotification) { window.showNotification('✅ تم ربط نظام الإشعارات بنجاح', 'success'); }"
    );
  }

  @override
  void dispose() {
    _statusTimer?.cancel();
    _authPollingTimer?.cancel();
    _connectivitySubscription?.cancel();
    _audioPlayer.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Stack(
          children: [
            InAppWebView(
              initialUrlRequest: URLRequest(url: WebUri("https://driver.zoonasd.com/")),
              initialSettings: InAppWebViewSettings(
                javaScriptEnabled: true,
                domStorageEnabled: true,
                databaseEnabled: true,
                useShouldOverrideUrlLoading: true,
                mediaPlaybackRequiresUserGesture: false,
                allowsInlineMediaPlayback: true,
                safeBrowsingEnabled: true,
                allowFileAccessFromFileURLs: true,
                allowUniversalAccessFromFileURLs: true,
              ),
              onWebViewCreated: (controller) => _webViewController = controller,
              onLoadStart: (controller, url) {
                setState(() => _isLoading = true);
              },
              onLoadStop: (controller, url) async {
                setState(() => _isLoading = false);
                _startAuthPolling(controller);
              },
              shouldOverrideUrlLoading: (controller, navigationAction) async {
                var uri = navigationAction.request.url!;
                if (!["http", "https", "file", "chrome", "data", "javascript", "about"].contains(uri.scheme)) {
                  if (await canLaunchUrl(uri)) {
                    await launchUrl(uri);
                    return NavigationActionPolicy.CANCEL;
                  }
                }
                return NavigationActionPolicy.ALLOW;
              },
              onConsoleMessage: (controller, consoleMessage) {
                debugPrint("🌐 Browser Console: ${consoleMessage.message}");
              },
            ),
            if (_isLoading)
              const Center(child: CircularProgressIndicator(color: Color(0xFF4f46e5))),
            if (!_isOnline)
              Positioned(
                top: 0, left: 0, right: 0,
                child: Container(
                  color: Colors.red,
                  padding: const EdgeInsets.all(4),
                  child: const Text("لا يوجد اتصال بالإنترنت", textAlign: TextAlign.center, style: TextStyle(color: Colors.white, fontSize: 12)),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
