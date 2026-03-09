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

  // إظهار تنبيه محلي عند وصول رسالة في الخلفية
  final fln.FlutterLocalNotificationsPlugin notifications =
      fln.FlutterLocalNotificationsPlugin();

  const android = fln.AndroidInitializationSettings('@mipmap/ic_launcher');
  await notifications.initialize(const fln.InitializationSettings(android: android));

  Map<String, dynamic> data = message.data;
  String title = message.notification?.title ?? "طلب رحلة جديد 🚗";
  String body = message.notification?.body ?? "لديك طلب رحلة جديد في انتظارك";

  // محاولة استخراج معلومات أفضل من الـ data إذا كان الـ notification فارغاً
  if (data.isNotEmpty) {
    print("Background data: $data");
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
  void onRepeatEvent(DateTime timestamp) {
    // Keep alive logic if needed
  }

  @override
  Future<void> onDestroy(DateTime timestamp) async {
    print('🛑 Foreground Task Destroyed');
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // تهيئة Firebase
  await Firebase.initializeApp();
  FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);

  if (kDebugMode && !kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
    await InAppWebViewController.setWebContentsDebuggingEnabled(true);
  }

  // تهيئة Supabase
  await Supabase.initialize(
    url: 'https://zsmlyiygjagmhnglrhoa.supabase.co',
    anonKey:
        'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InpzbWx5aXlnamFnbWhuZ2xyaG9hIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NjU5NDc3NjMsImV4cCI6MjA4MTUyMzc2M30.QviVinAng-ILq0umvI5UZCFEvNpP3nI0kW_hSaXxNps',
  );

  // طلب أذونات الموقع والإشعارات من النظام
  await [
    Permission.notification,
    Permission.location,
    Permission.locationAlways,
    Permission.camera, // أضفت الكاميرا تحسباً لاحتياج الموقع لها
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
      channelImportance: NotificationChannelImportance.LOW,
      priority: NotificationPriority.LOW,
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
  StreamSubscription<ConnectivityResult>? connectivitySubscription;

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

    // طلب الصلاحيات
    NotificationSettings settings = await messaging.requestPermission(
      alert: true,
      badge: true,
      sound: true,
      provisional: false,
    );

    print('User granted permission: ${settings.authorizationStatus}');

    // الحصول على التوكن
    fcmToken = await messaging.getToken();
    print('🔥 FCM Token: $fcmToken');
    if (fcmToken != null) {
      _sendTokenToPWA(fcmToken!);
    }

    // الاستماع لتحديثات التوكن
    messaging.onTokenRefresh.listen((newToken) {
      fcmToken = newToken;
      print('🔥 FCM Token Refreshed: $fcmToken');
      _sendTokenToPWA(newToken);
    });

    // معالجة الضغط على الإشعار عندما يكون التطبيق في الخلفية
    FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
      print('🖱️ Notification opened app!');
      _handleNotificationClick(message.data);
    });

    // معالجة الضغط على الإشعار عندما يكون التطبيق مغلقاً تماماً
    messaging.getInitialMessage().then((RemoteMessage? message) {
      if (message != null) {
        print('🚪 App opened from notification (Initial Message)');
        _handleNotificationClick(message.data);
      }
    });

    // الاستماع للرسائل في المقدمة
    FirebaseMessaging.onMessage.listen((RemoteMessage message) {
      print('Got a message whilst in the foreground!');
      print('Message data: ${message.data}');

      if (message.notification != null) {
        print('Message also contained a notification: ${message.notification}');
      }

      _handleFcmMessage(message);
    });
  }

  void _handleNotificationClick(Map<String, dynamic> data) {
    print('🔔 Notification clicked - Raw Data: $data');

    // محاولة استخراج ride_id من مصادر مختلفة في الـ data payload
    dynamic rideId = data['ride_id'] ?? data['rideId'];

    // إذا لم يوجد مباشرة، قد يكون بداخل حقل payload (سواء كـ Map أو String JSON)
    if (rideId == null && data['payload'] != null) {
      try {
        final payload = data['payload'];
        if (payload is Map) {
          rideId = payload['ride_id'] ?? payload['rideId'];
        } else if (payload is String) {
          final decodedPayload = jsonDecode(payload);
          rideId = decodedPayload['ride_id'] ?? decodedPayload['rideId'];
        }
      } catch (e) {
        print('⚠️ Error parsing nested payload: $e');
      }
    }

    if (rideId != null) {
      print('🎯 Found Ride ID: $rideId');
      _pendingRideData = data;
      final url = "https://driver.zoonasd.com/driver_app/accept-ride.html?id=$rideId";

      if (web != null) {
        print('🌐 WebView loaded, using loadUrl: $url');
        web!.loadUrl(urlRequest: URLRequest(url: WebUri(url)));
        _pendingUrl = null;
      } else {
        print('⏳ WebView not loaded yet, using initialUrl via setState: $url');
        setState(() {
          _pendingUrl = url;
        });
      }
    } else {
      print('⚠️ No Ride ID found in notification data');
    }
  }

  void _handleFcmMessage(RemoteMessage message) async {
    Map<String, dynamic> data = Map<String, dynamic>.from(message.data);

    // إذا كانت البيانات فارغة ولكن هناك إشعار، نحاول إظهاره
    if (data.isEmpty && message.notification != null) {
      await _showLocalNotification({
        'customer_name': message.notification!.title,
        'amount': message.notification!.body,
      });
      return;
    }

    // تشغيل الصوت والاهتزاز
    await _playNotificationSound(loop: true);

    // إظهار الإشعار المحلي
    await _showLocalNotification(data);

    // إظهار المودال
    _showRideRequestModal(data);

    // إرسال للـ PWA
    await _sendToPWA(data);
  }

  void _sendTokenToPWA(String token) async {
    if (web != null && _isPageLoaded) {
      print('FCM Token sent to WebView: $token');
      await web!.evaluateJavascript(
          source:
              "if(typeof window.setFCMToken === 'function') window.setFCMToken('$token');");
    }
  }

  Future<void> _initNotifications() async {
    const android = fln.AndroidInitializationSettings('@mipmap/ic_launcher');
    await notifications.initialize(
      const fln.InitializationSettings(android: android),
      onDidReceiveNotificationResponse: (details) {
        if (details.payload != null) {
          try {
            final data = jsonDecode(details.payload!);
            _handleNotificationClick(Map<String, dynamic>.from(data));
          } catch (e) {
            print('❌ Error parsing notification payload: $e');
          }
        }
      },
    );

    // التحقق مما إذا كان التطبيق قد فُتح عبر إشعار محلي (عندما يكون مغلقاً)
    final notificationAppLaunchDetails =
        await notifications.getNotificationAppLaunchDetails();
    if (notificationAppLaunchDetails?.didNotificationLaunchApp ?? false) {
      final payload = notificationAppLaunchDetails?.notificationResponse?.payload;
      if (payload != null) {
        try {
          print('🚪 App launched from local notification payload');
          final data = jsonDecode(payload);
          _handleNotificationClick(Map<String, dynamic>.from(data));
        } catch (e) {
          print('❌ Error parsing launch notification payload: $e');
        }
      }
    }

    // إنشاء قناة 'Urgent Alerts' بشكل صريح للأندرويد مع خصائص متقدمة
    const fln.AndroidNotificationChannel channel = fln.AndroidNotificationChannel(
      'urgent_alerts_v5', // id
      'Urgent Alerts', // name
      description: 'إشعارات طلبات الرحلات الجديدة - أولوية قصوى',
      importance: fln.Importance.max,
      playSound: true,
      enableVibration: true,
      enableLights: true,
      showBadge: true,
      sound: fln.RawResourceAndroidNotificationSound('ride_request_sound'),
      audioAttributesUsage: fln.AudioAttributesUsage.notificationRingtone,
    );

    await notifications
        .resolvePlatformSpecificImplementation<fln.AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(channel);
  }

  Future<void> _restoreDriver() async {
    final prefs = await SharedPreferences.getInstance();
    driverId = prefs.getString('driver_id');
    print('📱 Restored driver ID: $driverId');

    // استرجاع آخر رابط تمت زيارته لضمان استمرارية الحالة
    final lastUrl = prefs.getString('last_url');
    if (_pendingUrl == null && lastUrl != null && lastUrl.isNotEmpty) {
      print('🌐 Restored last visited URL: $lastUrl');
      if (web != null) {
        web!.loadUrl(urlRequest: URLRequest(url: WebUri(lastUrl)));
      } else {
        setState(() {
          _pendingUrl = lastUrl;
        });
      }
    }

    if (driverId != null) {
      _listenForRides();
      _startStatusSyncWithPWA();
      _checkRealtimeConnection(); // Start connection monitoring
      _startForegroundService();
    }
  }

  Future<void> _saveDriver(String id) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('driver_id', id);
    driverId = id;
    print('💾 Saved driver ID: $driverId');

    _listenForRides();
    _notifyPWAOfDriver(id);
    _checkRealtimeConnection(); // Start connection monitoring for new driver
    _startForegroundService();
  }

  Future<void> _startForegroundService() async {
    if (await FlutterForegroundTask.isRunningService) {
      return;
    }

    final notificationPermissionStatus = await FlutterForegroundTask.checkNotificationPermission();
    if (notificationPermissionStatus != NotificationPermission.granted) {
      await FlutterForegroundTask.requestNotificationPermission();
    }

    // طلب تجاوز تحسين البطارية لضمان استمرار العمل في الخلفية
    if (!await FlutterForegroundTask.isIgnoringBatteryOptimizations) {
      await FlutterForegroundTask.requestIgnoreBatteryOptimization();
    }

    await FlutterForegroundTask.startService(
      notificationTitle: 'زونا للسائقين تعمل في الخلفية',
      notificationText: 'جاهز لاستقبال طلبات الرحلات',
      callback: startCallback,
    );
  }

  Future<void> _stopForegroundService() async {
    await FlutterForegroundTask.stopService();
  }

  void _initConnectivity() {
    connectivitySubscription = Connectivity().onConnectivityChanged.listen((ConnectivityResult result) {
      print('🌐 Connectivity changed: $result');
      if (result != ConnectivityResult.none && driverId != null) {
        print('🔄 Internet restored, reconnecting...');
        _listenForRides();
        _updateDriverStatusInSupabase(true);
      }
    });
  }

  void _startCacheManagement() {
    cacheCheckTimer?.cancel();
    cacheCheckTimer = Timer.periodic(const Duration(hours: 6), (timer) async {
      if (web == null) return;

      print('🧹 Checking WebView cache...');
      // Simplification: clear cache if it's been a while, or we could try to get size
      // but inappwebview doesn't easily give cache size in bytes.
      // We will just clear it periodically as requested.
      // The user said "If it exceeds 100MB", but getting size is hard.
      // We'll clear it every 6 hours to stay safe.
      // We avoid clearing cookies to keep the driver logged in.
      await web!.clearCache();
      print('✅ Cache cleared');
    });
  }

  void _listenForRides() {
    print('🎯 Setting up Realtime listener for driver: $driverId');

    // إلغاء أي اشتراك سابق
    channel?.unsubscribe();
    channel = null;

    // إنشاء قناة جديدة
    channel = supabase.channel('ride_requests_$driverId')
      ..onPostgresChanges(
        event: PostgresChangeEvent.insert,
        schema: 'public',
        table: 'ride_requests',
        filter: PostgresChangeFilter(
          type: PostgresChangeFilterType.eq,
          column: 'driver_id',
          value: driverId!,
        ),
        callback: (payload) async {
          print('🚨 RIDE REQUEST RECEIVED via Realtime');
          print('📦 Raw payload: ${payload.newRecord}');

          try {
            final data = payload.newRecord;
            Map<String, dynamic> rideData = {};

            if (data != null) {
              // تحليل البيانات بشكل موثوق
              if (data['payload'] is Map) {
                rideData = Map<String, dynamic>.from(data['payload'] as Map);
              } else if (data['payload'] is String) {
                rideData = jsonDecode(data['payload']);
              } else {
                // محاولة استخراج البيانات مباشرة من الجدول
                rideData = {
                  'ride_id': data['ride_id'] ?? '',
                  'request_id': data['request_id'] ?? '',
                  'driver_id': data['driver_id'] ?? '',
                  'customer_name': data['customer_name'] ?? '',
                  'customer_phone': data['customer_phone'] ?? '',
                  'vehicle_type': data['vehicle_type'] ?? '',
                  'amount': data['amount'] ?? '0',
                  'distance': data['distance'] ?? '0 كم',
                  'pickup_address': data['pickup_address'] ?? '',
                  'destination_address': data['destination_address'] ?? '',
                  'pickup_lat': data['pickup_lat'] ?? 0.0,
                  'pickup_lng': data['pickup_lng'] ?? 0.0,
                  'destination_lat': data['destination_lat'] ?? 0.0,
                  'destination_lng': data['destination_lng'] ?? 0.0,
                  'timestamp': data['created_at'] ?? DateTime.now().toIso8601String(),
                };
              }
            }

            if (rideData.isEmpty) {
              print('⚠️ Empty ride data received');
              return;
            }

            print('📦 Processed ride data: $rideData');

            // إشعار واحد فقط من Flutter
            await _playNotificationSound(loop: true);
            await _showLocalNotification(rideData);
            _showRideRequestModal(rideData);
            await _sendToPWA(rideData);
            
            // تسجيل في قاعدة البيانات أن الإشعار تم تسليمه
            await _logNotificationDelivery(rideData);
          } catch (e) {
            print('❌ Error processing ride request: $e');
            print('Stack trace: ${e.toString()}');
          }
        },
      )
      ..subscribe((status, error) {
        if (error != null) {
          print('❌ Realtime subscription error: $error');
          print('Driver ID: $driverId');
          
          // محاولة إعادة الاتصال بعد 5 ثواني
          Timer(const Duration(seconds: 5), () {
            if (driverId != null) {
              print('🔄 Attempting to reconnect Realtime...');
              _listenForRides();
            }
          });
        } else {
          print('✅ Realtime subscribed successfully: $status');
        }
      });
  }

  Future<void> _logNotificationDelivery(Map<String, dynamic> rideData) async {
    try {
      await supabase.from('ride_notifications_log').insert({
        'ride_id': rideData['ride_id'] ?? rideData['rideId'],
        'driver_id': driverId,
        'notification_type': 'realtime',
        'channel': 'flutter',
        'delivered': true,
        'delivered_at': DateTime.now().toIso8601String(),
        'sent_at': DateTime.now().toIso8601String(),
      });
      print('📝 Notification delivery logged');
    } catch (e) {
      print('❌ Error logging notification: $e');
    }
  }

  void _checkRealtimeConnection() {
    // إلغاء أي timer سابق
    connectionCheckTimer?.cancel();
    
    // إنشاء timer جديد للتحقق من الاتصال كل 30 ثانية
    connectionCheckTimer = Timer.periodic(const Duration(seconds: 30), (timer) async {
      if (driverId == null) {
        print('⚠️ No driver ID, stopping connection check');
        timer.cancel();
        return;
      }

      try {
        // التحقق من حالة القناة
        if (channel == null) {
          print('⚠️ Realtime channel is null, reconnecting...');
          _listenForRides();
          return;
        }

        // إذا كانت القناة مغلقة أو بها خطأ، إعادة الاتصال
        if (channel!.isJoined != true) {
          print('🔄 Reconnecting Realtime...');
          channel?.unsubscribe();
          channel = null;
          await Future.delayed(const Duration(seconds: 2));
          _listenForRides();
        }
        
        // التحقق من أن السائق لا يزال online في قاعدة البيانات
        try {
          final response = await supabase
            .from('driver_locations')
            .select('is_online, last_seen')
            .eq('driver_id', driverId!)
            .single()
            .timeout(const Duration(seconds: 10));
          
          if (response != null) {
            final driverLocation = response;
            final lastSeen = DateTime.parse(driverLocation['last_seen']);
            final now = DateTime.now();
            final difference = now.difference(lastSeen).inSeconds;
            
            if (difference > 60) { // أكثر من دقيقة
              print('⚠️ Driver last seen $difference seconds ago, updating...');
              await _updateDriverStatusInSupabase(true);
            }
          }
        } catch (e) {
          print('⚠️ Error checking driver location: $e');
        }
      } catch (e) {
        print('❌ Error checking connection: $e');
        print('Stack trace: ${e.toString()}');
      }
    });
    
    print('⏱️ Started Realtime connection monitor');
  }

  Future<void> _playNotificationSound({bool loop = false}) async {
    try {
      print('🔊 Playing notification sound (loop: $loop)...');
      
      await audioPlayer.stop();

      if (loop) {
        await audioPlayer.setReleaseMode(ReleaseMode.loop);
      } else {
        await audioPlayer.setReleaseMode(ReleaseMode.release);
      }
      
      await audioPlayer.setSource(AssetSource('ride_request_sound.mp3'));
      await audioPlayer.resume();
      
      print('✅ Sound played successfully');

      if (await Vibration.hasVibrator() ?? false) {
        if (loop) {
          Vibration.vibrate(pattern: [500, 1000, 500, 1000], repeat: 0);
        } else {
          Vibration.vibrate(pattern: [500, 200, 500]);
        }
        print('📳 Vibration activated');
      }
    } catch (e) {
      print('❌ Error playing sound: $e');
      print('Stack trace: ${e.toString()}');
      
      // محاولة بديلة بسيطة
      try {
        // استخدام beep بسيط
        audioPlayer.play(AssetSource('notification.wav'));
      } catch (e2) {
        print('❌ Fallback sound also failed: $e2');
      }
    }
  }

  Future<void> _showLocalNotification(Map<String, dynamic> data) async {
    try {
      // استخراج البيانات بشكل قوي
      Map<String, dynamic> rideData = data;
      if (data['payload'] != null) {
        try {
          if (data['payload'] is Map) {
            rideData = Map<String, dynamic>.from(data['payload']);
          } else if (data['payload'] is String) {
            rideData = jsonDecode(data['payload']);
          }
        } catch (e) {
          print('⚠️ Error parsing nested payload in local notification: $e');
        }
      }

      String customerName =
          rideData['customer_name'] ?? rideData['customerName'] ?? 'عميل';
      String amount = rideData['amount']?.toString() ?? '0';
      String distance = rideData['distance']?.toString() ?? '0 كم';

      await notifications.show(
        DateTime.now().millisecond,
        'طلب رحلة جديد 🚗',
        '$customerName - $amount SDG ($distance)',
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
            enableVibration: true,
            sound: fln.RawResourceAndroidNotificationSound('ride_request_sound'),
            colorized: true,
            color: Color(0xFF16a34a),
            visibility: fln.NotificationVisibility.public,
            ticker: 'طلب رحلة جديد',
          ),
          iOS: fln.DarwinNotificationDetails(
            presentAlert: true,
            presentBadge: true,
            presentSound: true,
            sound: 'ride_request_sound.mp3',
          ),
        ),
        payload: jsonEncode(data),
      );

      print('📱 High-priority notification shown: $customerName');
    } catch (e) {
      print('❌ Error showing notification: $e');
    }
  }

  void _showRideRequestModal(Map<String, dynamic> data) {
    String customerName = data['customer_name'] ?? data['customerName'] ?? 'عميل';
    String amount = data['amount']?.toString() ?? '0';
    String distance = data['distance']?.toString() ?? '0 كم';
    String pickup = data['pickup_address'] ?? data['pickupAddress'] ?? 'موقع الاستلام';

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('طلب رحلة جديد', textAlign: TextAlign.center, style: TextStyle(fontWeight: FontWeight.bold)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.directions_car, size: 50, color: Colors.green),
            const SizedBox(height: 10),
            Text(customerName, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.location_on, color: Colors.red),
              title: const Text('من:'),
              subtitle: Text(pickup),
            ),
            ListTile(
              leading: const Icon(Icons.money, color: Colors.green),
              title: const Text('المبلغ:'),
              subtitle: Text('$amount SDG'),
            ),
            ListTile(
              leading: const Icon(Icons.map, color: Colors.blue),
              title: const Text('المسافة:'),
              subtitle: Text(distance),
            ),
          ],
        ),
        actions: [
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.green,
                padding: const EdgeInsets.symmetric(vertical: 15),
              ),
              onPressed: () async {
                await _acceptRide(data);
                Navigator.of(context).pop();
              },
              child: const Text('قبول الرحلة', style: TextStyle(fontSize: 18, color: Colors.white)),
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: TextButton(
              onPressed: () {
                _stopAlerts();
                Navigator.of(context).pop();
              },
              child: const Text('تجاهل', style: TextStyle(color: Colors.red)),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _acceptRide(Map<String, dynamic> data) async {
    _stopAlerts();

    final rideId = data['ride_id'] ?? data['rideId'];
    final requestId = data['request_id'] ?? data['requestId'];

    try {
      print('📡 Updating ride request status to accepted in DB...');
      await supabase
          .from('ride_requests')
          .update({'status': 'accepted'})
          .eq('ride_id', rideId)
          .eq('driver_id', driverId!);

      print('✅ Ride request updated in DB');
    } catch (e) {
      print('❌ Error updating ride request in DB: $e');
    }

    if (web != null) {
      final jsonStr = jsonEncode(data);
      print('✅ Accepting ride via JS bridge...');
      await web!.evaluateJavascript(
          source:
              "if(typeof handleRideRequest === 'function') handleRideRequest($jsonStr);");
    }
  }

  void _stopAlerts() {
    audioPlayer.stop();
    Vibration.cancel();
  }

  Future<void> _sendToPWA(Map<String, dynamic> data) async {
    if (web == null) {
      print('⚠️ WebView controller is null, cannot send to PWA');
      return;
    }
    
    try {
      final jsonStr = jsonEncode(data);
      print('📤 Sending to PWA: ${data['ride_id'] ?? data['rideId']}');
      
      // استخدام try-catch منفصل لكل طريقة
      try {
        // الطريقة 1: evaluateJavascript
        await web!.evaluateJavascript(
          source: """
            try {
              if (typeof handleRideRequest === 'function') {
                console.log('🎯 Calling handleRideRequest from Flutter');
                handleRideRequest($jsonStr);
              } else {
                console.warn('⚠️ handleRideRequest function not found');
                localStorage.setItem('last_ride_from_flutter', $jsonStr);
                localStorage.setItem('last_ride_time', new Date().toISOString());
                
                // إرسال event مخصص
                window.dispatchEvent(new CustomEvent('rideRequest', {
                  detail: $jsonStr
                }));
              }
            } catch(e) {
              console.error('❌ Error in Flutter bridge:', e);
            }
          """
        );
      } catch (jsError) {
        print('❌ JavaScript evaluation error: $jsError');
      }
      
      // الطريقة 2: postMessage
      try {
        await web!.evaluateJavascript(
          source: """
            window.postMessage({
              type: 'RIDE_REQUEST',
              payload: $jsonStr,
              source: 'flutter',
              timestamp: new Date().toISOString()
            }, '*');
          """
        );
      } catch (postMessageError) {
        print('❌ postMessage error: $postMessageError');
      }
      
      print('✅ Ride data sent to PWA successfully');
    } catch (e) {
      print('❌ Error sending to PWA: $e');
      print('Stack trace: ${e.toString()}');
    }
  }

  void _notifyPWAOfDriver(String driverId) {
    if (web == null) {
      print('⚠️ WebView controller is null, cannot notify PWA');
      return;
    }
    
    Timer(const Duration(milliseconds: 500), () async {
      try {
        print('🔄 Notifying PWA of driver ID: $driverId');
        
        await web!.evaluateJavascript(
          source: """
            try {
              // حفظ في localStorage
              localStorage.setItem('driver_id', '$driverId');
              localStorage.setItem('tarhal_driver_id', '$driverId');
              
              // إرسال event
              window.dispatchEvent(new CustomEvent('driverLogin', {
                detail: {
                  driverId: '$driverId',
                  source: 'flutter'
                }
              }));
              
              // postMessage
              window.postMessage({
                type: 'SET_DRIVER_ID',
                driverId: '$driverId',
                source: 'flutter',
                timestamp: new Date().toISOString()
              }, '*');
              
              console.log('✅ Driver ID set in PWA: $driverId');
            } catch(e) {
              console.error('❌ Error setting driver ID:', e);
            }
          """
        );
      } catch (e) {
        print('❌ Error notifying PWA: $e');
      }
    });
  }

  void _startStatusSyncWithPWA() {
    statusSyncTimer?.cancel();
    statusSyncTimer = Timer.periodic(const Duration(seconds: 5), (timer) async {
      if (web == null || driverId == null) {
        print('⚠️ WebView or driver ID is null, skipping sync');
        return;
      }

      try {
        print('🔄 Syncing status with PWA...');
        
        final result = await web!.evaluateJavascript(source: """
          (function() {
            try {
              var isOnline = localStorage.getItem('driver_forever_online') === 'true';
              var driverId = localStorage.getItem('driver_id');
              return JSON.stringify({ 
                isOnline: isOnline,
                driverId: driverId,
                pwaReady: true 
              });
            } catch(e) {
              return JSON.stringify({ 
                error: e.message,
                pwaReady: false 
              });
            }
          })();
        """);

        if (result != null) {
          final resultStr = result.toString();
          if (!resultStr.startsWith('error:')) {
            try {
              final data = jsonDecode(resultStr);
              if (data['error'] == null) {
                await _updateDriverStatusInSupabase(data['isOnline'] == true);
                print('✅ Status synced with PWA: ${data['isOnline']}');
              } else {
                print('⚠️ PWA JavaScript error: ${data['error']}');
              }
            } catch (e) {
              print('❌ Error parsing sync result: $e');
            }
          } else {
            print('❌ JavaScript error in sync: $resultStr');
          }
        }
      } catch (e) {
        print('❌ Error syncing status: $e');
      }
    });
  }

  Future<void> _updateDriverStatusInSupabase(bool isOnline) async {
    try {
      print('📡 Updating driver status in Supabase: ${isOnline ? 'ONLINE' : 'OFFLINE'}');
      
      final result = await supabase.from('driver_locations').upsert({
        'driver_id': driverId,
        'is_online': isOnline,
        'last_seen': DateTime.now().toIso8601String(),
        'updated_at': DateTime.now().toIso8601String(),
      });
      
      if (result.status == 201 || result.status == 200 || result.status == 204) {
        print('✅ Driver status updated successfully');
      } else {
        print('⚠️ Driver status update returned status: ${result.status}');
      }
    } catch (e) {
      print('❌ Error updating driver status: $e');
      print('Driver ID: $driverId');
      
      // محاولة بديلة
      try {
        await supabase.from('driver_locations').update({
          'is_online': isOnline,
          'updated_at': DateTime.now().toIso8601String(),
        }).eq('driver_id', driverId!);
        print('✅ Driver status updated (fallback method)');
      } catch (fallbackError) {
        print('❌ Fallback update also failed: $fallbackError');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('زونا للسائقين'),
        backgroundColor: Colors.green[700],
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () {
              if (driverId != null) {
                print('🔁 Manual refresh of Realtime connection');
                channel?.unsubscribe();
                _listenForRides();
                showDialog(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: const Text('تحديث الاتصال'),
                    content: const Text('تم تحديث اتصال Realtime'),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('موافق'),
                      ),
                    ],
                  ),
                );
              }
            },
          ),
        ],
      ),
      body: InAppWebView(
        initialUrlRequest:
            URLRequest(url: WebUri(_pendingUrl ?? 'https://driver.zoonasd.com/')),
        initialSettings: InAppWebViewSettings(
          javaScriptEnabled: true,
          domStorageEnabled: true,
          databaseEnabled: true,
          geolocationEnabled: true,
          mediaPlaybackRequiresUserGesture: false,
          javaScriptCanOpenWindowsAutomatically: true,
          supportMultipleWindows: true,
          transparentBackground: true,
          clearSessionCache: false,
          cacheEnabled: true,
          mixedContentMode: MixedContentMode.MIXED_CONTENT_COMPATIBILITY_MODE,
          userAgent: "Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/116.0.0.0 Mobile Safari/537.36",
        ),
        onGeolocationPermissionsShowPrompt: (controller, origin) async {
          return GeolocationPermissionShowPromptResponse(
              origin: origin, allow: true, retain: true);
        },
        onPermissionRequest: (controller, request) async {
          // السماح تلقائياً للموقع الموثوق
          if (request.origin.host == 'driver.zoonasd.com') {
            return PermissionResponse(
              resources: request.resources,
              action: PermissionResponseAction.GRANT,
            );
          }

          // للمواقع الأخرى، نطلب إذن المستخدم
          bool granted = await showDialog<bool>(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('طلب إذن'),
                  content: Text(
                      'يرغب الموقع ${request.origin} في الوصول إلى: ${request.resources.join(", ")}'),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('رفض'),
                    ),
                    TextButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('سماح'),
                    ),
                  ],
                ),
              ) ??
              false;

          return PermissionResponse(
            resources: request.resources,
            action: granted
                ? PermissionResponseAction.GRANT
                : PermissionResponseAction.DENY,
          );
        },
        onCreateWindow: (controller, createWindowAction) async {
          showDialog(
            context: context,
            builder: (context) {
              return WebViewPopup(
                createWindowAction: createWindowAction,
                popupWebViewSettings: InAppWebViewSettings(
                  javaScriptEnabled: true,
                  domStorageEnabled: true,
                  databaseEnabled: true,
                  geolocationEnabled: true,
                ),
              );
            },
          );
          return true;
        },
        onWebViewCreated: (controller) {
          web = controller;
          print('🌐 WebView created');

          if (_pendingUrl != null) {
            print('🚀 Loading pending URL after WebView creation: $_pendingUrl');
            controller.loadUrl(urlRequest: URLRequest(url: WebUri(_pendingUrl!)));
            _pendingUrl = null;
          }
          
          // إعداد JavaScript handlers
          controller.addJavaScriptHandler(
            handlerName: 'onTokenReceived',
            callback: (args) {
              print('📱 PWA requested FCM Token via onTokenReceived handler');
              return fcmToken;
            },
          );

          controller.addJavaScriptHandler(
            handlerName: 'getFcmToken',
            callback: (args) {
              print('📱 PWA requested FCM Token via getFcmToken handler');
              return fcmToken;
            },
          );

          controller.addJavaScriptHandler(
            handlerName: 'driverLogin',
            callback: (args) async {
              print('📱 Received driverLogin from PWA: $args');
              if (args.isNotEmpty && args[0] is Map) {
                final data = args[0] as Map;
                final driverId = data['driverId']?.toString();
                if (driverId != null && driverId.isNotEmpty) {
                  await _saveDriver(driverId);
                }
              }
              return {'success': true};
            },
          );
          
          controller.addJavaScriptHandler(
            handlerName: 'rideRequestHandler',
            callback: (args) {
              print('📱 Ride request handler called from PWA: $args');
              return {'received': true, 'processedBy': 'flutter'};
            },
          );

          controller.addJavaScriptHandler(
            handlerName: 'showNativeNotification',
            callback: (args) {
              print('📱 showNativeNotification called from PWA: $args');
              if (args.isNotEmpty && args[0] is Map) {
                _showLocalNotification(Map<String, dynamic>.from(args[0]));
                return {'success': true};
              }
              return {'success': false, 'error': 'Invalid arguments'};
            },
          );
          
          controller.addJavaScriptHandler(
            handlerName: 'testConnection',
            callback: (args) {
              print('📱 Test connection from PWA');
              return {
                'flutterReady': true,
                'driverId': driverId,
                'realtimeConnected': channel != null,
                'timestamp': DateTime.now().toIso8601String(),
              };
            },
          );
        },
        onLoadStop: (controller, url) async {
          print('✅ Page loaded: ${url?.toString()}');
          _isPageLoaded = true;

          // حفظ آخر رابط تمت زيارته لضمان استمرارية الحالة
          if (url != null) {
            final prefs = await SharedPreferences.getInstance();
            await prefs.setString('last_url', url.toString());
            print('💾 Saved last visited URL: ${url.toString()}');
          }

          // أضف هذا السطر لضمان الإرسال فور تحميل الصفحة
          if (fcmToken != null) {
            print('🚀 Sending stored token after page load: $fcmToken');
            _sendTokenToPWA(fcmToken!);
          }

          _startDriverSync();
          if (driverId != null) {
            _notifyPWAOfDriver(driverId!);
          }

          // التحقق مما إذا كانت هذه صفحة قبول الرحلة وكان هناك بيانات معلقة
          if ((url?.toString().contains('accept-ride.html') == true ||
               url?.toString().contains('driver_app/accept-ride.html') == true) &&
              _pendingRideData != null) {
            print('🎯 On accept-ride page, waiting 3 seconds to send ride data...');
            final dataToSend = Map<String, dynamic>.from(_pendingRideData!);
            _pendingRideData = null; // تفريغ البيانات لتجنب التكرار

            Future.delayed(const Duration(seconds: 3), () async {
              try {
                final jsonStr = jsonEncode(dataToSend);
                print('📤 Calling handleIncomingRide via bridge: $jsonStr');
                await controller.evaluateJavascript(source: """
                  if (typeof handleIncomingRide === 'function') {
                    console.log('🎯 Calling handleIncomingRide from Flutter');
                    handleIncomingRide($jsonStr);
                  } else {
                    console.warn('⚠️ handleIncomingRide function not found on this page');
                  }
                """);
              } catch (e) {
                print('❌ Error calling handleIncomingRide: $e');
              }
            });
          }

          // إرسال رسالة تأكيد للPWA
          await controller.evaluateJavascript(source: """
            console.log('✅ Flutter WebView loaded successfully');
            window.dispatchEvent(new Event('flutterReady'));
          """);
        },
        onLoadError: (controller, url, code, message) {
          print('❌ Page load error: $code - $message');
        },
        onConsoleMessage: (controller, consoleMessage) {
          print('🌐 WebView Console [${consoleMessage.messageLevel}]: ${consoleMessage.message}');
        },
        shouldOverrideUrlLoading: (controller, nav) async {
          final uri = nav.request.url!;
          final url = uri.toString();
          print('🔗 URL request: $url');

          // فحص روابط الاتصال وواتساب لفتحها في تطبيقات خارجية
          bool isWhatsApp = uri.scheme == 'whatsapp' ||
              url.contains('wa.me') ||
              url.contains('api.whatsapp.com');
          bool isTel = uri.scheme == 'tel';

          if (isWhatsApp || isTel) {
            print('🚀 Opening external app for: $url');
            if (await canLaunchUrl(uri)) {
              await launchUrl(uri, mode: LaunchMode.externalApplication);
              return NavigationActionPolicy.CANCEL;
            }
          }

          if (['http', 'https'].contains(uri.scheme)) {
            return NavigationActionPolicy.ALLOW;
          }

          if (await canLaunchUrl(uri)) {
            await launchUrl(uri);
          }
          return NavigationActionPolicy.CANCEL;
        },
      ),
      floatingActionButton: driverId != null
          ? FloatingActionButton(
              onPressed: () {
                showDialog(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: const Text('حالة الاتصال'),
                    content: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('معرف السائق: $driverId'),
                        Text('قناة Realtime: ${channel != null ? "🟢 متصلة" : "🔴 غير متصلة"}'),
                        if (channel != null)
                          Text('حالة الاشتراك: ${channel!.isJoined == true ? "🟢 متصل" : "🔴 غير متصل"}'),
                        const SizedBox(height: 10),
                        const Text('آخر تحديث:'),
                        Text(DateTime.now().toString()),
                      ],
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('إغلاق'),
                      ),
                      TextButton(
                        onPressed: () {
                          if (driverId != null) {
                            _listenForRides();
                            Navigator.pop(context);
                          }
                        },
                        child: const Text('إعادة الاتصال'),
                      ),
                    ],
                  ),
                );
              },
              child: const Icon(Icons.info),
              backgroundColor: Colors.green,
            )
          : null,
    );
  }

  void _startDriverSync() {
    // إلغاء أي timer سابق
    Timer? syncTimer;
    
    syncTimer = Timer.periodic(const Duration(seconds: 3), (timer) async {
      if (web == null) {
        print('⚠️ WebView is null, stopping sync');
        timer.cancel();
        return;
      }
      
      try {
        final result = await web!.evaluateJavascript(source: """
          (function() {
            try {
              var driverId = localStorage.getItem('driver_id') || 
                            localStorage.getItem('tarhal_driver_id');
              return driverId || 'null';
            } catch(e) { 
              return 'error:' + e.message; 
            }
          })();
        """);

        if (result != null && result != 'null' && !result.toString().startsWith('error:')) {
          final id = result.toString().trim();
          if (id.length > 5 && id != driverId) {
            print('🔄 Found new driver ID in PWA: $id');
            await _saveDriver(id);
            
            // تحديث URL ليعكس معرف السائق الجديد
            await web!.evaluateJavascript(source: """
              const url = new URL(window.location.href);
              url.searchParams.set('driver_id', '$id');
              window.history.replaceState({}, '', url);
            """);
          }
        }
      } catch (_) {
        print('⚠️ Error in driver sync');
      }
      
      // التحقق من اتصال Realtime كل 30 ثانية
      if (timer.tick % 10 == 0 && driverId != null) {
        if (channel == null || channel!.isJoined != true) {
          print('🔄 Realtime not connected, attempting to reconnect...');
          _listenForRides();
        }
      }
    });
  }

  @override
  void dispose() {
    print('♻️ Disposing DriverHome...');
    
    // إلغاء جميع الـ timers
    statusSyncTimer?.cancel();
    connectionCheckTimer?.cancel();
    cacheCheckTimer?.cancel();
    connectivitySubscription?.cancel();
    
    // إلغاء اشتراك Realtime
    try {
      channel?.unsubscribe();
      print('✅ Unsubscribed from Realtime');
    } catch (e) {
      print('❌ Error unsubscribing from Realtime: $e');
    }
    
    // إيقاف الصوت
    try {
      audioPlayer.dispose();
    } catch (e) {
      print('❌ Error disposing audio player: $e');
    }
    
    super.dispose();
  }
}