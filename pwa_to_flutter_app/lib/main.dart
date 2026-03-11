import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart' as fln;
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:vibration/vibration.dart';
import 'webview_popup.dart';

@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
  print("Handling a background message: ${message.messageId}");

  final fln.FlutterLocalNotificationsPlugin notifications =
      fln.FlutterLocalNotificationsPlugin();

  const android = fln.AndroidInitializationSettings('@mipmap/ic_launcher');
  await notifications.initialize(const fln.InitializationSettings(android: android));

  Map<String, dynamic> data = message.data;
  String title = message.notification?.title ?? "طلب رحلة جديد 🚗";
  String body = message.notification?.body ?? "لديك طلب رحلة جديد في انتظارك";

  if (data.isNotEmpty) {
    Map<String, dynamic> rideData = data;
    if (data['payload'] != null) {
      try {
        if (data['payload'] is Map) {
          rideData = Map<String, dynamic>.from(data['payload']);
        } else if (data['payload'] is String) {
          rideData = jsonDecode(data['payload']);
        }
      } catch (e) {
        print('⚠️ Error parsing nested payload in background: $e');
      }
    }

    if (message.notification == null) {
      final customerName =
          rideData['customer_name'] ?? rideData['customerName'] ?? 'عميل';
      final amount = rideData['amount']?.toString() ?? '---';
      title = 'طلب رحلة من $customerName 🚗';
      body = 'المبلغ المتوقع: $amount SDG';
    }
  }

  await notifications.show(
    DateTime.now().millisecond,
    title,
    body,
    const fln.NotificationDetails(
      android: fln.AndroidNotificationDetails(
        'urgent_alerts_v5',
        'Urgent Alerts',
        channelDescription: 'إشعارات طلبات الرحلات الجديدة - أولوية قصوى',
        importance: fln.Importance.max,
        priority: fln.Priority.high,
        fullScreenIntent: true,
        category: fln.AndroidNotificationCategory.call,
        playSound: true,
        sound: fln.RawResourceAndroidNotificationSound('ride_request_sound'),
        colorized: true,
        color: Color(0xFF16a34a),
        visibility: fln.NotificationVisibility.public,
        ticker: 'طلب رحلة جديد',
        ongoing: true,
        autoCancel: false,
      ),
    ),
    payload: jsonEncode(data),
  );
}

@pragma('vm:entry-point')
void startCallback() {
  FlutterForegroundTask.setTaskHandler(MyTaskHandler());
}

class MyTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    print('🚀 Foreground Task Started');
  }

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    print('🛑 Foreground Task Destroyed');
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);

  if (kDebugMode && !kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
    await InAppWebViewController.setWebContentsDebuggingEnabled(true);
  }

  await Supabase.initialize(
    url: 'https://zsmlyiygjagmhnglrhoa.supabase.co',
    anonKey:
        'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InpzbWx5aXlnamFnbWhuZ2xyaG9hIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NjU5NDc3NjMsImV4cCI6MjA4MTUyMzc2M30.QviVinAng-ILq0umvI5UZCFEvNpP3nI0kW_hSaXxNps',
  );

  await [
    Permission.notification,
    Permission.location,
    Permission.locationAlways,
    Permission.camera,
    Permission.ignoreBatteryOptimizations,
  ].request();

  _initForegroundTask();
  runApp(const DriverApp());
}

void _initForegroundTask() {
  FlutterForegroundTask.init(
    androidNotificationOptions: AndroidNotificationOptions(
      channelId: 'foreground_service',
      channelName: 'Foreground Service Notification',
      channelDescription: 'This notification appears when the foreground service is running.',
      channelImportance: NotificationChannelImportance.HIGH,
      priority: NotificationPriority.HIGH,
    ),
    iosNotificationOptions: const IOSNotificationOptions(
      showNotification: true,
      playSound: false,
    ),
    foregroundTaskOptions: ForegroundTaskOptions(
      eventAction: ForegroundTaskEventAction.repeat(5000),
      autoRunOnBoot: true,
      allowWakeLock: true,
      allowWifiLock: true,
    ),
  );
}

class DriverApp extends StatelessWidget {
  const DriverApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: DriverHome(),
    );
  }
}

class DriverHome extends StatefulWidget {
  const DriverHome({super.key});

  @override
  State<DriverHome> createState() => _DriverHomeState();
}

class _DriverHomeState extends State<DriverHome> {
  final supabase = Supabase.instance.client;
  final audioPlayer = AudioPlayer();
  final fln.FlutterLocalNotificationsPlugin notifications =
      fln.FlutterLocalNotificationsPlugin();

  InAppWebViewController? web;
  bool _isPageLoaded = false;
  String? driverId;
  String? fcmToken;
  Map<String, dynamic>? _pendingRideData;
  String? _pendingUrl;
  RealtimeChannel? channel;
  Timer? statusSyncTimer;
  Timer? connectionCheckTimer;
  Timer? cacheCheckTimer;
  
  // --- تصحيح نوع المتغير ليتوافق مع connectivity_plus v6 ---
  StreamSubscription<List<ConnectivityResult>>? connectivitySubscription;

  @override
  void initState() {
    super.initState();
    _initNotifications();
    _initFirebaseMessaging();
    _restoreDriver();
    _initConnectivity();
    _startCacheManagement();
  }

  Future<void> _initFirebaseMessaging() async {
    FirebaseMessaging messaging = FirebaseMessaging.instance;
    await messaging.requestPermission(alert: true, badge: true, sound: true);
    fcmToken = await messaging.getToken();
    if (fcmToken != null) _sendTokenToPWA(fcmToken!);

    messaging.onTokenRefresh.listen((newToken) {
      fcmToken = newToken;
      _sendTokenToPWA(newToken);
    });

    FirebaseMessaging.onMessageOpenedApp.listen((message) => _handleNotificationClick(message.data));
    messaging.getInitialMessage().then((message) {
      if (message != null) _handleNotificationClick(message.data);
    });

    FirebaseMessaging.onMessage.listen((message) => _handleFcmMessage(message));
  }

  void _handleNotificationClick(Map<String, dynamic> data) {
    dynamic rideId = data['ride_id'] ?? data['rideId'];
    if (rideId == null && data['payload'] != null) {
      try {
        final payload = data['payload'];
        final decoded = payload is Map ? payload : jsonDecode(payload);
        rideId = decoded['ride_id'] ?? decoded['rideId'];
      } catch (_) {}
    }

    if (rideId != null) {
      _pendingRideData = data;
      final url = "https://driver.zoonasd.com/driver_app/accept-ride.html?id=$rideId";
      if (web != null) {
        web!.loadUrl(urlRequest: URLRequest(url: WebUri(url)));
      } else {
        setState(() => _pendingUrl = url);
      }
    }
  }

  void _handleFcmMessage(RemoteMessage message) async {
    Map<String, dynamic> data = Map<String, dynamic>.from(message.data);
    if (data.isEmpty && message.notification != null) {
      await _showLocalNotification({
        'customer_name': message.notification!.title,
        'amount': message.notification!.body,
      });
      return;
    }
    await _playNotificationSound(loop: true);
    await _showLocalNotification(data);
    _showRideRequestModal(data);
    await _sendToPWA(data);
  }

  void _sendTokenToPWA(String token) async {
    if (web != null && _isPageLoaded) {
      await web!.evaluateJavascript(source: "if(typeof window.setFCMToken === 'function') window.setFCMToken('$token');");
    }
  }

  Future<void> _initNotifications() async {
    const android = fln.AndroidInitializationSettings('@mipmap/ic_launcher');
    await notifications.initialize(const fln.InitializationSettings(android: android),
      onDidReceiveNotificationResponse: (details) {
        if (details.payload != null) _handleNotificationClick(jsonDecode(details.payload!));
      }
    );

    const chan = fln.AndroidNotificationChannel(
      'urgent_alerts_v5', 'Urgent Alerts',
      description: 'إشعارات طلبات الرحلات الجديدة',
      importance: fln.Importance.max,
      playSound: true,
      sound: fln.RawResourceAndroidNotificationSound('ride_request_sound'),
    );
    await notifications.resolvePlatformSpecificImplementation<fln.AndroidFlutterLocalNotificationsPlugin>()?.createNotificationChannel(chan);
  }

  Future<void> _restoreDriver() async {
    final prefs = await SharedPreferences.getInstance();
    driverId = prefs.getString('driver_id');
    final lastUrl = prefs.getString('last_url');
    if (_pendingUrl == null && lastUrl != null && lastUrl.isNotEmpty) {
      if (web != null) web!.loadUrl(urlRequest: URLRequest(url: WebUri(lastUrl)));
      else setState(() => _pendingUrl = lastUrl);
    }
    if (driverId != null) {
      _listenForRides();
      _startStatusSyncWithPWA();
      _checkRealtimeConnection();
      _startForegroundService();
    }
  }

  Future<void> _saveDriver(String id) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('driver_id', id);
    driverId = id;
    _listenForRides();
    _notifyPWAOfDriver(id);
    _checkRealtimeConnection();
    _startForegroundService();
  }

  Future<void> _startForegroundService() async {
    if (await FlutterForegroundTask.isRunningService) return;
    await FlutterForegroundTask.startService(
      notificationTitle: 'زونا للسائقين تعمل في الخلفية',
      notificationText: 'جاهز لاستقبال طلبات الرحلات',
      callback: startCallback,
      serviceTypes: [ForegroundServiceTypes.specialUse],
    );
  }

  // --- تصحيح معالج الاتصال ليتوافق مع القائمة المستلمة من الإصدار الجديد ---
  void _initConnectivity() {
    connectivitySubscription = Connectivity().onConnectivityChanged.listen((List<ConnectivityResult> results) {
      if (results.isNotEmpty && results.first != ConnectivityResult.none && driverId != null) {
        _listenForRides();
        _updateDriverStatusInSupabase(true);
      }
    });
  }

  void _startCacheManagement() {
    cacheCheckTimer = Timer.periodic(const Duration(hours: 6), (timer) async {
      if (web != null) await web!.clearCache();
    });
  }

  void _listenForRides() {
    channel?.unsubscribe();
    channel = supabase.channel('ride_requests_$driverId')
      ..onPostgresChanges(
        event: PostgresChangeEvent.insert,
        schema: 'public',
        table: 'ride_requests',
        filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'driver_id', value: driverId!),
        callback: (payload) async {
          final data = payload.newRecord;
          Map<String, dynamic> rideData = {};
          if (data != null) {
            if (data['payload'] is Map) rideData = Map<String, dynamic>.from(data['payload']);
            else if (data['payload'] is String) rideData = jsonDecode(data['payload']);
            else rideData = Map<String, dynamic>.from(data);
          }
          await _playNotificationSound(loop: true);
          await _showLocalNotification(rideData);
          _showRideRequestModal(rideData);
          await _sendToPWA(rideData);
        },
      )..subscribe();
  }

  void _checkRealtimeConnection() {
    connectionCheckTimer?.cancel();
    connectionCheckTimer = Timer.periodic(const Duration(seconds: 30), (timer) async {
      if (driverId == null) { timer.cancel(); return; }
      if (channel == null || channel!.isJoined != true) _listenForRides();
    });
  }

  Future<void> _playNotificationSound({bool loop = false}) async {
    try {
      await audioPlayer.stop();
      await audioPlayer.setReleaseMode(loop ? ReleaseMode.loop : ReleaseMode.release);
      await audioPlayer.setSource(AssetSource('ride_request_sound.mp3'));
      await audioPlayer.resume();
      if (await Vibration.hasVibrator() ?? false) {
        loop ? Vibration.vibrate(pattern: [500, 1000, 500, 1000], repeat: 0) : Vibration.vibrate(duration: 500);
      }
    } catch (_) {}
  }

  Future<void> _showLocalNotification(Map<String, dynamic> data) async {
    try {
      String customerName = data['customer_name'] ?? data['customerName'] ?? 'عميل';
      String amount = data['amount']?.toString() ?? '0';
      await notifications.show(
        DateTime.now().millisecond, 'طلب رحلة جديد 🚗', '$customerName - $amount SDG',
        const fln.NotificationDetails(
          android: fln.AndroidNotificationDetails(
            'urgent_alerts_v5',
            'Urgent Alerts',
            importance: fln.Importance.max,
            priority: fln.Priority.high,
            fullScreenIntent: true,
            category: fln.AndroidNotificationCategory.call,
            playSound: true,
            sound: fln.RawResourceAndroidNotificationSound('ride_request_sound'),
          ),
        ),
        payload: jsonEncode(data),
      );
    } catch (_) {}
  }

  void _showRideRequestModal(Map<String, dynamic> data) {
    showDialog(context: context, barrierDismissible: false, builder: (context) => AlertDialog(
      title: const Text('طلب رحلة جديد', textAlign: TextAlign.center),
      content: Text("${data['customer_name'] ?? 'عميل'} - ${data['amount'] ?? 0} SDG"),
      actions: [
        ElevatedButton(onPressed: () { _acceptRide(data); Navigator.pop(context); }, child: const Text('قبول')),
        TextButton(onPressed: () { _stopAlerts(); Navigator.pop(context); }, child: const Text('تجاهل'))
      ],
    ));
  }

  Future<void> _acceptRide(Map<String, dynamic> data) async {
    _stopAlerts();
    try {
      await supabase.from('ride_requests').update({'status': 'accepted'}).eq('ride_id', data['ride_id'] ?? data['rideId']).eq('driver_id', driverId!);
    } catch (_) {}
    if (web != null) await web!.evaluateJavascript(source: "if(typeof handleRideRequest === 'function') handleRideRequest(${jsonEncode(data)});");
  }

  void _stopAlerts() { audioPlayer.stop(); Vibration.cancel(); }

  Future<void> _sendToPWA(Map<String, dynamic> data) async {
    if (web == null) return;
    await web!.evaluateJavascript(source: "if(typeof handleRideRequest === 'function') handleRideRequest(${jsonEncode(data)});");
  }

  void _notifyPWAOfDriver(String id) {
    if (web == null) return;
    web!.evaluateJavascript(source: "localStorage.setItem('driver_id', '$id');");
  }

  void _startStatusSyncWithPWA() {
    statusSyncTimer?.cancel();
    statusSyncTimer = Timer.periodic(const Duration(seconds: 5), (timer) async {
      if (web == null || driverId == null) return;
      final res = await web!.evaluateJavascript(source: "localStorage.getItem('driver_forever_online')");
      if (res != null) _updateDriverStatusInSupabase(res == 'true');
    });
  }

  Future<void> _updateDriverStatusInSupabase(bool isOnline) async {
    if (driverId == null) return;
    try {
      await supabase.from('driver_locations').upsert({
        'driver_id': driverId, 'is_online': isOnline, 'last_seen': DateTime.now().toIso8601String(),
      }).timeout(const Duration(seconds: 15));
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('زونا للسائقين'), backgroundColor: Colors.green[700]),
      body: InAppWebView(
        initialUrlRequest: URLRequest(url: WebUri(_pendingUrl ?? 'https://driver.zoonasd.com/')),
        initialSettings: InAppWebViewSettings(
          javaScriptEnabled: true,
          domStorageEnabled: true,
          geolocationEnabled: true,
          allowFileAccessFromFileURLs: true,
          allowUniversalAccessFromFileURLs: true,
          useShouldOverrideUrlLoading: true,
          userAgent: "Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/116.0.0.0 Mobile Safari/537.36",
        ),
        onGeolocationPermissionsShowPrompt: (controller, origin) async => GeolocationPermissionShowPromptResponse(origin: origin, allow: true, retain: true),
        onPermissionRequest: (controller, request) async => PermissionResponse(resources: request.resources, action: PermissionResponseAction.GRANT),
        onWebViewCreated: (controller) {
          web = controller;
          controller.addJavaScriptHandler(handlerName: 'driverLogin', callback: (args) {
            if (args.isNotEmpty && args[0] is Map) _saveDriver(args[0]['driverId'].toString());
          });
        },
        onLoadStop: (controller, url) async {
          _isPageLoaded = true;
          if (url != null) {
            final prefs = await SharedPreferences.getInstance();
            await prefs.setString('last_url', url.toString());
          }
          if (fcmToken != null) _sendTokenToPWA(fcmToken!);
          _startDriverSync();
        },
        shouldOverrideUrlLoading: (controller, nav) async {
          final uri = nav.request.url!;
          final url = uri.toString();
          
          final bool isExternalApp = 
              url.startsWith('whatsapp://') || 
              url.startsWith('tel:') || 
              url.startsWith('sms:') || 
              url.startsWith('mailto:') ||
              url.contains('wa.me') || 
              url.contains('api.whatsapp.com');

          if (isExternalApp) {
            try {
              await launchUrl(uri, mode: LaunchMode.externalApplication);
            } catch (e) {
              print('❌ Error opening external app: $e');
            }
            return NavigationActionPolicy.CANCEL;
          }

          if (uri.scheme == 'http' || uri.scheme == 'https') {
            return NavigationActionPolicy.ALLOW;
          }

          return NavigationActionPolicy.CANCEL;
        },
      ),
    );
  }

  void _startDriverSync() {
    Timer.periodic(const Duration(seconds: 3), (timer) async {
      if (web == null) return;
      final res = await web!.evaluateJavascript(source: "localStorage.getItem('driver_id')");
      if (res != null && res != 'null' && res != driverId) _saveDriver(res);
    });
  }

  @override
  void dispose() {
    statusSyncTimer?.cancel();
    connectionCheckTimer?.cancel();
    connectivitySubscription?.cancel();
    audioPlayer.dispose();
    super.dispose();
  }
}
