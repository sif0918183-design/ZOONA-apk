import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'; 
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart' as fln;
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:vibration/vibration.dart';
import 'webview_popup.dart';

// معرّف ثابت لإشعار طلب الرحلة — يضمن أن كل إشعار جديد يحلّ محل السابق
const int kRideNotificationId = 1001;

// مشغل الصوت العالمي — يُستخدم فقط في الـ main isolate حتى يمكن إيقافه
final AudioPlayer globalAudioPlayer = AudioPlayer(playerId: 'global_driver_player');

@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();

  // نحفظ ride_id في SharedPreferences حتى يشغّل التطبيق الصوت بنفسه عند الفتح
  // (لا نشغّل الصوت هنا لأن هذا الـ handler يعمل في Dart isolate منفصل)
  try {
    final prefs = await SharedPreferences.getInstance();
    final rideId = message.data['ride_id'] ?? message.data['rideId'] ?? '';
    if (rideId.toString().isNotEmpty) {
      await prefs.setString('pending_ride_id', rideId.toString());
    }
    await prefs.setString('pending_ride_data', jsonEncode(message.data));
  } catch (_) {}

  final fln.FlutterLocalNotificationsPlugin notifications = fln.FlutterLocalNotificationsPlugin();
  const android = fln.AndroidInitializationSettings('@mipmap/ic_launcher');
  await notifications.initialize(const fln.InitializationSettings(android: android));

  Map<String, dynamic> data = message.data;
  String title = message.notification?.title ?? "طلب رحلة جديد";
  String body = message.notification?.body ?? "لديك طلب رحلة جديد في انتظارك";

  // استخدام معرّف ثابت (kRideNotificationId) بدلاً من عشوائي
  // → كل إشعار جديد يحلّ محل القديم ولا يتراكم
  await notifications.show(
    kRideNotificationId, title, body,
    const fln.NotificationDetails(
      android: fln.AndroidNotificationDetails(
        'emergency_channel_v10',
        'تنبيهات الطوارئ - تراكا',
        importance: fln.Importance.max,
        priority: fln.Priority.high,
        fullScreenIntent: true,
        playSound: true,
        sound: fln.RawResourceAndroidNotificationSound('ride_request_sound'),
        enableVibration: true,
        channelShowBadge: true,
        visibility: fln.NotificationVisibility.public,
        onlyAlertOnce: true,
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
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}
  @override
  void onRepeatEvent(DateTime timestamp) {}
  @override
  Future<void> onDestroy(DateTime timestamp) async {}
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  
  await Firebase.initializeApp();
  FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);

  if (kDebugMode && !kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
    await InAppWebViewController.setWebContentsDebuggingEnabled(true);
  }

  await Supabase.initialize(
    url: 'https://zsmlyiygjagmhnglrhoa.supabase.co',
    anonKey: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InpzbWx5aXlnamFnbWhuZ2xyaG9hIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NjU5NDc3NjMsImV4cCI6MjA4MTUyMzc2M30.QviVinAng-ILq0umvI5UZCFEvNpP3nI0kW_hSaXxNps',
  );

  await [Permission.notification, Permission.location, Permission.locationAlways, Permission.camera, Permission.ignoreBatteryOptimizations].request();
  _initForegroundTask();
  runApp(const DriverApp());
}

void _initForegroundTask() {
  FlutterForegroundTask.init(
    androidNotificationOptions: AndroidNotificationOptions(
      channelId: 'foreground_service',
      channelName: 'خدمة تراكا تعمل حالياً',
      channelImportance: NotificationChannelImportance.MAX,
      priority: NotificationPriority.HIGH,
    ),
    iosNotificationOptions: const IOSNotificationOptions(showNotification: true, playSound: false),
    foregroundTaskOptions: ForegroundTaskOptions(eventAction: ForegroundTaskEventAction.repeat(5000), autoRunOnBoot: true, allowWakeLock: true, allowWifiLock: true),
  );
}

class DriverApp extends StatelessWidget {
  const DriverApp({super.key});
  @override
  Widget build(BuildContext context) {
    return const MaterialApp(debugShowCheckedModeBanner: false, home: DriverHome());
  }
}

class DriverHome extends StatefulWidget {
  const DriverHome({super.key});
  @override
  State<DriverHome> createState() => _DriverHomeState();
}

class _DriverHomeState extends State<DriverHome> {
  final supabase = Supabase.instance.client;
  final fln.FlutterLocalNotificationsPlugin notifications = fln.FlutterLocalNotificationsPlugin();
  InAppWebViewController? web;
  bool _isPageLoaded = false;
  String? driverId;
  String? fcmToken;
  String? _pendingUrl;
  RealtimeChannel? channel;
  Timer? statusSyncTimer;
  StreamSubscription<ConnectivityResult>? connectivitySubscription;

  @override
  void initState() {
    super.initState();
    // نُهيئ الإشعارات أولاً ثم نتحقق من إشعار الإطلاق قبل أي شيء آخر
    _initNotificationsAndCheckLaunch().then((_) {
      _initFirebaseMessaging();
      _restoreDriver();
      _initConnectivity();
    });
  }

  Future<void> _initNotificationsAndCheckLaunch() async {
    const androidInit = fln.AndroidInitializationSettings('@mipmap/ic_launcher');
    await notifications.initialize(
      const fln.InitializationSettings(android: androidInit),
      onDidReceiveNotificationResponse: (details) {
        if (details.payload != null) {
          try { _handleNotificationClick(jsonDecode(details.payload!)); } catch (_) {}
        }
      },
    );

    final androidImplementation = notifications.resolvePlatformSpecificImplementation<fln.AndroidFlutterLocalNotificationsPlugin>();
    const chan = fln.AndroidNotificationChannel(
      'emergency_channel_v10',
      'تنبيهات الطوارئ - تراكا',
      description: 'هذه القناة مخصصة لطلبات الرحلات الهامة جداً',
      importance: fln.Importance.max,
      playSound: true,
      enableVibration: true,
      sound: fln.RawResourceAndroidNotificationSound('ride_request_sound'),
    );
    await androidImplementation?.createNotificationChannel(chan);

    // تحقق من هل التطبيق فُتح بالضغط على إشعار (حالة التطبيق المُغلَق)
    // هذا هو المسار الصحيح لمعالجة نقرة الإشعار عند الإطلاق من الخلفية
    final launchDetails = await notifications.getNotificationAppLaunchDetails();
    if (launchDetails?.didNotificationLaunchApp == true) {
      final payload = launchDetails?.notificationResponse?.payload;
      if (payload != null) {
        try { _handleNotificationClick(jsonDecode(payload)); } catch (_) {}
        return; // لا نحتاج فحص pending_ride_id إذا عندنا payload
      }
    }

    // في حال فشل الـ payload، نتحقق من pending_ride_id المحفوظ في الـ background handler
    try {
      final prefs = await SharedPreferences.getInstance();
      final pendingRideId = prefs.getString('pending_ride_id');
      if (pendingRideId != null && pendingRideId.isNotEmpty) {
        final pendingDataStr = prefs.getString('pending_ride_data');
        Map<String, dynamic> data = {};
        if (pendingDataStr != null) {
          try { data = jsonDecode(pendingDataStr); } catch (_) {}
        }
        data['ride_id'] = pendingRideId;
        _handleNotificationClick(data);
        // نمسح البيانات المعلّقة بعد معالجتها
        await prefs.remove('pending_ride_id');
        await prefs.remove('pending_ride_data');
      }
    } catch (_) {}
  }

  Future<void> _initFirebaseMessaging() async {
    FirebaseMessaging messaging = FirebaseMessaging.instance;
    await messaging.requestPermission(alert: true, badge: true, sound: true);
    fcmToken = await messaging.getToken();
    if (fcmToken != null) _sendTokenToPWA(fcmToken!);
    messaging.onTokenRefresh.listen((newToken) { fcmToken = newToken; _sendTokenToPWA(newToken); });
    // حالة: التطبيق في الخلفية والمستخدم يضغط إشعار Firebase (ليس flutter_local_notifications)
    FirebaseMessaging.onMessageOpenedApp.listen((message) => _handleNotificationClick(message.data));
    messaging.getInitialMessage().then((message) { if (message != null) _handleNotificationClick(message.data); });
    // حالة: التطبيق في المقدمة ويصل إشعار
    FirebaseMessaging.onMessage.listen((message) => _handleFcmMessage(message));
  }

  // معالج النقر على الإشعار — يشغّل الصوت في main isolate ثم يفتح صفحة القبول
  void _handleNotificationClick(Map<String, dynamic> data) {
    dynamic rideId = data['ride_id'] ?? data['rideId'];

    if (rideId == null && data['payload'] != null) {
      try {
        final payloadData = data['payload'] is String ? jsonDecode(data['payload']) : data['payload'];
        rideId = payloadData['ride_id'] ?? payloadData['rideId'];
      } catch (_) {}
    }

    if (rideId != null) {
      // نشغّل الصوت هنا في الـ main isolate حتى يمكن إيقافه عند الضغط
      _playNotificationSound();

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
    _playNotificationSound();
    await _showLocalNotification(data);
    _showRideRequestModal(data);
    await _sendToPWA(data);
  }

  void _sendTokenToPWA(String token) async {
    if (web != null && _isPageLoaded) {
      await web!.evaluateJavascript(source: "if(typeof window.setFCMToken === 'function') window.setFCMToken('$token');");
    }
  }

  Future<void> _restoreDriver() async {
    final prefs = await SharedPreferences.getInstance();
    driverId = prefs.getString('driver_id');
    final lastUrl = prefs.getString('last_url');

    // لا نعيد فتح صفحة accept-ride.html من جلسة سابقة — كانت لطلب قديم
    final shouldRestore = _pendingUrl == null &&
        lastUrl != null &&
        lastUrl.isNotEmpty &&
        !lastUrl.contains('accept-ride.html');

    if (shouldRestore) {
      if (web != null) web!.loadUrl(urlRequest: URLRequest(url: WebUri(lastUrl!)));
      else setState(() => _pendingUrl = lastUrl);
    }
    if (driverId != null) { _listenForRides(); _startStatusSyncWithPWA(); _startForegroundService(); }
  }

  Future<void> _saveDriver(String id) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('driver_id', id);
    driverId = id;
    _listenForRides();
    _notifyPWAOfDriver(id);
    _startForegroundService();
  }

  Future<void> _startForegroundService() async {
    if (await FlutterForegroundTask.isRunningService) return;
    await FlutterForegroundTask.startService(
      notificationTitle: 'Tracka يعمل في الخلفية',
      notificationText: 'جاهز لاستقبال طلبات الرحلات',
      callback: startCallback,
    );
  }

  void _initConnectivity() {
    connectivitySubscription = Connectivity().onConnectivityChanged.listen((result) {
      if (result != ConnectivityResult.none && driverId != null) { _listenForRides(); _updateDriverStatusInSupabase(true); }
    });
  }

  void _listenForRides() {
    if (driverId == null) return;
    channel?.unsubscribe();
    channel = supabase.channel('ride_requests_$driverId')
      ..onPostgresChanges(
        event: PostgresChangeEvent.insert,
        schema: 'public',
        table: 'ride_requests',
        filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'driver_id', value: driverId!),
        callback: (payload) async {
          final data = payload.newRecord;
          Map<String, dynamic> rideData = data != null ? Map<String, dynamic>.from(data) : {};
          _playNotificationSound();
          await _showLocalNotification(rideData);
          _showRideRequestModal(rideData);
          await _sendToPWA(rideData);
        },
      )..subscribe();
  }

  Future<void> _playNotificationSound() async {
    try {
      await globalAudioPlayer.stop();
      await globalAudioPlayer.setReleaseMode(ReleaseMode.loop);
      await globalAudioPlayer.play(AssetSource('ride_request_sound.mp3'), volume: 1.0);
      if (await Vibration.hasVibrator() ?? false) { Vibration.vibrate(pattern: [500, 1000], repeat: 0); }
    } catch (_) {}
  }

  Future<void> _showLocalNotification(Map<String, dynamic> data) async {
    try {
      String name = data['customer_name'] ?? 'عميل';
      String amount = data['amount']?.toString() ?? '0';
      // معرّف ثابت → إشعار جديد يحلّ محل القديم ولا يتكرر
      await notifications.show(
        kRideNotificationId,
        'طلب رحلة جديد',
        '$name - $amount SDG',
        const fln.NotificationDetails(
          android: fln.AndroidNotificationDetails(
            'emergency_channel_v10',
            'تنبيهات الطوارئ - تراكا',
            importance: fln.Importance.max,
            priority: fln.Priority.high,
            playSound: true,
            sound: fln.RawResourceAndroidNotificationSound('ride_request_sound'),
            onlyAlertOnce: true,
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
    try { await supabase.from('ride_requests').update({'status': 'accepted'}).eq('ride_id', data['ride_id'] ?? data['rideId']).eq('driver_id', driverId!); } catch (_) {}
    if (web != null) await web!.evaluateJavascript(source: "if(typeof handleRideRequest === 'function') handleRideRequest(${jsonEncode(data)});");
  }

  void _stopAlerts() {
    // إيقاف مشغّل الصوت (يعمل دائماً في main isolate → يُوقَف بشكل موثوق)
    globalAudioPlayer.stop();
    // إيقاف الاهتزاز
    Vibration.cancel();
    // إلغاء الإشعار النشط من لوح الإشعارات
    notifications.cancel(kRideNotificationId);
  }

  Future<void> _sendToPWA(Map<String, dynamic> data) async {
    if (web == null) return;
    await web!.evaluateJavascript(source: "if(typeof handleRideRequest === 'function') handleRideRequest(${jsonEncode(data)});");
  }

  void _notifyPWAOfDriver(String id) { if (web == null) return; web!.evaluateJavascript(source: "localStorage.setItem('driver_id', '$id');"); }

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
    try { await supabase.from('driver_locations').upsert({'driver_id': driverId, 'is_online': isOnline, 'last_seen': DateTime.now().toIso8601String()}).timeout(const Duration(seconds: 15)); } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: AnnotatedRegion<SystemUiOverlayStyle>(
        value: const SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: Brightness.dark,
          systemNavigationBarColor: Colors.white,
          systemNavigationBarIconBrightness: Brightness.dark,
        ),
        child: SafeArea(
          child: InAppWebView(
            initialUrlRequest: URLRequest(url: WebUri(_pendingUrl ?? 'https://driver.zoonasd.com/')),
            initialSettings: InAppWebViewSettings(
              javaScriptEnabled: true,
              domStorageEnabled: true,
              geolocationEnabled: true,
              useShouldOverrideUrlLoading: true,
              userAgent: "Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/116.0.0.0 Mobile Safari/537.36",
            ),
            onWebViewCreated: (controller) {
              web = controller;
              controller.addJavaScriptHandler(handlerName: 'driverLogin', callback: (args) { if (args.isNotEmpty && args[0] is Map) _saveDriver(args[0]['driverId'].toString()); });
              controller.addJavaScriptHandler(handlerName: 'stopAlerts', callback: (args) { _stopAlerts(); });

              if (_pendingUrl != null) {
                controller.loadUrl(urlRequest: URLRequest(url: WebUri(_pendingUrl!)));
              }
            },
            onGeolocationPermissionsShowPrompt: (controller, origin) async => GeolocationPermissionShowPromptResponse(origin: origin, allow: true, retain: true),
            onLoadStop: (controller, url) async {
              _isPageLoaded = true;
              if (url != null) {
                final String currentUrl = url.toString();
                final prefs = await SharedPreferences.getInstance();
                // لا نحفظ accept-ride.html كآخر صفحة — لأنها مؤقتة لطلب رحلة
                if (!currentUrl.contains('accept-ride.html')) {
                  await prefs.setString('last_url', currentUrl);
                  _stopAlerts();
                }
              }
              if (fcmToken != null) _sendTokenToPWA(fcmToken!);
              _startDriverSync();
            },
            shouldOverrideUrlLoading: (controller, nav) async {
              final uri = nav.request.url!;
              if (['whatsapp', 'tel', 'sms', 'mailto'].contains(uri.scheme) || uri.toString().contains('wa.me')) {
                try { await launchUrl(uri, mode: LaunchMode.externalApplication); } catch (_) {}
                return NavigationActionPolicy.CANCEL;
              }
              return NavigationActionPolicy.ALLOW;
            },
          ),
        ),
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
    connectivitySubscription?.cancel();
    globalAudioPlayer.dispose();
    super.dispose();
  }
}
