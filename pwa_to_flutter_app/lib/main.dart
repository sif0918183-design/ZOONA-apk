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
  Map<Permission, PermissionStatus> statuses = await [
    Permission.notification,
    Permission.location,
    Permission.locationAlways,
  ].request();
  debugPrint("Permissions status: $statuses");
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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _supabase = Supabase.instance.client;
    
    _setupConnectivity();
    _setupOneSignalHandlers();
    
    // تحديث الحالة كل دقيقتين لضمان بقاء السائق متاحاً
    _statusTimer = Timer.periodic(const Duration(minutes: 2), (_) => _updateOnlineStatus(true));
  }

  void _setupConnectivity() {
    _connectivitySubscription = Connectivity().onConnectivityChanged.listen((result) {
      setState(() => _isOnline = result != ConnectivityResult.none);
    });
  }

  void _setupOneSignalHandlers() {
    OneSignal.shared.setNotificationWillShowInForegroundHandler((event) {
      _handleIncomingNotification(event.notification.additionalData);
      event.complete(event.notification);
    });
  }

  Future<void> _handleIncomingNotification(Map<String, dynamic>? data) async {
    if (data != null && _webViewController != null) {
      final jsonStr = jsonEncode(data);
      await _webViewController!.evaluateJavascript(source: "if(window.handleRideRequest) { window.handleRideRequest($jsonStr); }");
    }
  }

  Future<void> _updateOnlineStatus(bool online) async {
    if (_currentDriverId != null) {
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

  Future<void> _syncDriverData(InAppWebViewController controller) async {
    // محاولة جلب ID السائق من الـ Storage الخاص بالويب
    final result = await controller.evaluateJavascript(source: "localStorage.getItem('driver_id')");
    if (result != null && result.toString() != "null") {
      _currentDriverId = result.toString().replaceAll('"', '');
      
      // جلب توكن الإشعارات وتخزينه في قاعدة البيانات
      final deviceState = await OneSignal.shared.getDeviceState();
      if (deviceState?.userId != null) {
        await _supabase.from('drivers').update({
          'push_token': deviceState!.userId,
          'last_active': DateTime.now().toIso8601String(),
        }).eq('id', _currentDriverId!);
      }
      _updateOnlineStatus(true);
    }
  }

  @override
  void dispose() {
    _statusTimer?.cancel();
    _connectivitySubscription?.cancel();
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
                useShouldOverrideUrlLoading: true,
              ),
              onWebViewCreated: (controller) => _webViewController = controller,
              onLoadStop: (controller, url) async {
                setState(() => _isLoading = false);
                await _syncDriverData(controller);
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
