import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:vibration/vibration.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // ----------------- تهيئة Supabase -----------------
  await Supabase.initialize(
    url: 'https://zsmlyiygjagmhnglrhoa.supabase.co',
    anonKey: 'YOUR_SUPABASE_ANON_KEY',
  );

  // طلب أذونات الموقع والإشعارات
  await [
    Permission.notification,
    Permission.location,
    Permission.locationAlways,
  ].request();

  if (Platform.isAndroid) {
    await InAppWebViewController.setWebContentsDebuggingEnabled(kDebugMode);
  }

  runApp(const TarhalZoonaDriverApp());
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
    _restoreDriverId();

    // تحديث حالة السائق كل دقيقتين لضمان البقاء متصل
    _statusTimer = Timer.periodic(const Duration(minutes: 2), (_) => _updateOnlineStatus(true));
  }

  Future<void> _restoreDriverId() async {
    final prefs = await SharedPreferences.getInstance();
    final savedId = prefs.getString('synced_driver_id');
    if (savedId != null) {
      _currentDriverId = savedId;
      debugPrint("🔄 Restored driver_id: $savedId");
    }
  }

  void _setupConnectivity() {
    _connectivitySubscription = Connectivity().onConnectivityChanged.listen((result) {
      setState(() => _isOnline = result != ConnectivityResult.none);
    });
  }

  // ==================== Polling لمزامنة driver_id من WebView ====================
  void _startAuthPolling(InAppWebViewController controller) {
    _authPollingTimer?.cancel();
    _authPollingTimer = Timer.periodic(const Duration(seconds: 3), (timer) async {
      try {
        final dynamic result = await controller.evaluateJavascript(
          source: """
            (function() {
              try {
                let id = localStorage.getItem('driver_id') || localStorage.getItem('tarhal_driver_id');
                if (id && id.length > 5 && id !== "null") return id.toString().trim();
                return null;
              } catch(e) { return null; }
            })()
          """
        );

        if (result != null && result.toString() != "null") {
          final String driverId = result.toString();
          if (_currentDriverId != driverId) {
            await _syncDriver(driverId);
          }
        }
      } catch (e) {
        debugPrint("Polling error: $e");
      }
    });
  }

  Future<void> _syncDriver(String driverId) async {
    _currentDriverId = driverId;

    // حفظ محلي
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('synced_driver_id', driverId);

    // تحديث Supabase driver push info
    try {
      // يجب أن يكون push_subscription مسجل من PWA للسائق عند تسجيل الدخول
      await _supabase.from('drivers').upsert({
        'id': driverId,
        'last_active': DateTime.now().toIso8601String(),
      });
    } catch (e) {
      debugPrint("Supabase sync error: $e");
    }

    _updateOnlineStatus(true);
    debugPrint("✅ Driver $driverId synced successfully");

    // إخطار WebView بالنجاح
    await _webViewController?.evaluateJavascript(
      source: "if(window.showNotification) { window.showNotification('✅ تم ربط الإشعارات بنجاح', 'success'); }"
    );
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
        debugPrint("Error updating online status: $e");
      }
    }
  }

  // ==================== إشعارات داخل WebView ====================
  Future<void> _handleIncomingNotification(Map<String, dynamic>? data) async {
    if (data != null && _webViewController != null) {
      final jsonStr = jsonEncode(data);
      await _webViewController!.evaluateJavascript(
        source: "if(window.handleRideRequest) { window.handleRideRequest($jsonStr); }"
      );

      // تشغيل صوت واهتزاز
      try {
        await Vibration.vibrate(pattern: [500, 250, 500], intensities: [255, 0, 255]);
        await _audioPlayer.play(AssetSource('ride_request_sound.wav'));
      } catch (e) {
        debugPrint("Error triggering alert: $e");
      }
    }
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
                mediaPlaybackRequiresUserGesture: false,
                allowsInlineMediaPlayback: true,
                safeBrowsingEnabled: true,
                allowFileAccessFromFileURLs: true,
                allowUniversalAccessFromFileURLs: true,
              ),
              onWebViewCreated: (controller) => _webViewController = controller,
              onLoadStart: (controller, url) => setState(() => _isLoading = true),
              onLoadStop: (controller, url) async {
                setState(() => _isLoading = false);
                _startAuthPolling(controller);
              },
              shouldOverrideUrlLoading: (controller, navAction) async {
                final uri = navAction.request.url!;
                if (!["http", "https", "file", "chrome", "data", "javascript", "about"].contains(uri.scheme)) {
                  if (await canLaunchUrl(uri)) await launchUrl(uri);
                  return NavigationActionPolicy.CANCEL;
                }
                return NavigationActionPolicy.ALLOW;
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
                  child: const Text(
                    "لا يوجد اتصال بالإنترنت",
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white, fontSize: 12),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}