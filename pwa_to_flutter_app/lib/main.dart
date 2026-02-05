import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:vibration/vibration.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Supabase.initialize(
    url: 'https://zsmlyiygjagmhnglrhoa.supabase.co',
    anonKey: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InpzbWx5aXlnamFnbWhuZ2xyaG9hIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NjU5NDc3NjMsImV4cCI6MjA4MTUyMzc2M30.QviVinAng-ILq0umvI5UZCFEvNpP3nI0kW_hSaXxNps',
  );

  await Permission.notification.request();
  await Permission.location.request();

  runApp(const DriverApp());
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
  final FlutterLocalNotificationsPlugin notifications =
      FlutterLocalNotificationsPlugin();

  InAppWebViewController? web;
  String? driverId;
  RealtimeChannel? channel;
  Timer? statusSyncTimer;

  @override
  void initState() {
    super.initState();
    _initNotifications();
    _restoreDriver();
  }

  Future<void> _initNotifications() async {
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    await notifications.initialize(const InitializationSettings(android: android));
    
    // طلب إذن الإشعارات بشكل صريح
    await notifications
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.requestPermission();
  }

  Future<void> _restoreDriver() async {
    final prefs = await SharedPreferences.getInstance();
    driverId = prefs.getString('driver_id');
    print('📱 Restored driver ID: $driverId');
    
    if (driverId != null) {
      _listenForRides();
      _startStatusSyncWithPWA();
    }
  }

  Future<void> _saveDriver(String id) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('driver_id', id);
    driverId = id;
    print('💾 Saved driver ID: $driverId');
    
    // بدء الاستماع للرحلات
    _listenForRides();
    
    // إعلام PWA بالسائق الجديد
    _notifyPWAOfDriver(id);
  }

  void _listenForRides() {
    print('🎯 Setting up Realtime listener for driver: $driverId');
    
    // إلغاء أي اشتراك سابق
    channel?.unsubscribe();

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
          
          try {
            final data = payload.newRecord;
            print('📦 Payload data: $data');
            
            // استخراج البيانات بشكل آمن
            Map<String, dynamic> rideData = {};
            
            if (data != null) {
              if (data['payload'] is Map) {
                rideData = Map<String, dynamic>.from(data['payload'] as Map);
              } else if (data['payload'] is String) {
                rideData = jsonDecode(data['payload']);
              } else {
                rideData = Map<String, dynamic>.from(data);
              }
            }
            
            // التأكد من وجود البيانات الأساسية
            if (rideData.isEmpty) {
              print('⚠️ Empty ride data');
              return;
            }
            
            print('✅ Processed ride data: $rideData');
            
            // تشغيل الصوت والاهتزاز في الخلفية
            await _playNotificationSound();
            
            // عرض إشعار محلي
            await _showLocalNotification(rideData);
            
            // إرسال للـ PWA - وهذا هو الجزء المهم
            await _sendToPWA(rideData);
            
          } catch (e) {
            print('❌ Error processing ride request: $e');
          }
        },
      )
      ..subscribe((status, error) {
        if (error != null) {
          print('❌ Realtime subscription error: $error');
        } else {
          print('✅ Realtime subscribed successfully: $status');
        }
      });
  }

  Future<void> _playNotificationSound() async {
    try {
      // تحميل الصوت أولاً
      await audioPlayer.setSource(AssetSource('ride_request_sound.wav'));
      
      // تشغيل الصوت
      await audioPlayer.play(AssetSource('ride_request_sound.wav'));
      print('🔊 Sound played successfully');
      
      // اهتزاز إذا كان الجهاز يدعمه
      if (await Vibration.hasVibrator() ?? false) {
        Vibration.vibrate(pattern: [500, 200, 500]);
        print('📳 Vibration activated');
      }
    } catch (e) {
      print('❌ Error playing sound: $e');
    }
  }

  Future<void> _showLocalNotification(Map<String, dynamic> data) async {
    try {
      String customerName = data['customerName'] ?? data['customer_name'] ?? 'عميل';
      String amount = data['amount']?.toString() ?? '0';
      
      await notifications.show(
        0,
        'طلب رحلة جديد 🚗',
        '$customerName - $amount SDG',
        const NotificationDetails(
          android: AndroidNotificationDetails(
            'rides',
            'Ride Requests',
            channelDescription: 'طلبات الرحلات للسائقين',
            importance: Importance.max,
            priority: Priority.high,
            playSound: true,
            enableVibration: true,
            sound: RawResourceAndroidNotificationSound('ride_request_sound'),
          ),
        ),
      );
      print('📢 Local notification shown');
    } catch (e) {
      print('❌ Error showing notification: $e');
    }
  }

  Future<void> _sendToPWA(Map<String, dynamic> data) async {
    if (web == null) {
      print('⚠️ WebView not ready, cannot send to PWA');
      return;
    }
    
    try {
      // تحويل البيانات إلى JSON
      final jsonStr = jsonEncode(data);
      print('📤 Sending to PWA: $jsonStr');
      
      // طريقة 1: استخدام handleRideRequest
      final result1 = await web!.evaluateJavascript(
        source: """
          if (typeof handleRideRequest === 'function') {
            handleRideRequest($jsonStr);
            '✅ Sent via handleRideRequest';
          } else {
            '⚠️ handleRideRequest not found';
          }
        """
      );
      print('Result 1: $result1');
      
      // طريقة 2: استخدام FlutterBridge
      final result2 = await web!.evaluateJavascript(
        source: """
          if (window.FlutterBridge && window.FlutterBridge.receiveFromFlutter) {
            window.FlutterBridge.receiveFromFlutter({
              type: 'RIDE_REQUEST',
              payload: $jsonStr,
              source: 'flutter',
              timestamp: new Date().toISOString()
            });
            '✅ Sent via FlutterBridge';
          } else {
            '⚠️ FlutterBridge not found';
          }
        """
      );
      print('Result 2: $result2');
      
      // طريقة 3: وضع في localStorage
      await web!.evaluateJavascript(
        source: """
          localStorage.setItem('last_ride_from_flutter', $jsonStr);
          console.log('📦 Ride saved to localStorage');
        """
      );
      
      print('✅ Successfully sent ride request to PWA');
      
    } catch (e) {
      print('❌ Error sending to PWA: $e');
    }
  }

  void _notifyPWAOfDriver(String driverId) {
    if (web == null) return;
    
    // إرسال driver_id للـ PWA عبر عدة طرق
    Timer(const Duration(milliseconds: 500), () async {
      try {
        // الطريقة 1: localStorage
        await web!.evaluateJavascript(
          source: """
            localStorage.setItem('driver_id', '$driverId');
            localStorage.setItem('tarhal_driver_id', '$driverId');
            console.log('🆔 Driver ID set in localStorage: $driverId');
          """
        );
        
        // الطريقة 2: postMessage
        await web!.evaluateJavascript(
          source: """
            window.postMessage({
              type: 'SET_DRIVER_ID',
              driverId: '$driverId',
              source: 'flutter'
            }, '*');
          """
        );
        
        // الطريقة 3: FlutterBridge
        await web!.evaluateJavascript(
          source: """
            if (window.FlutterBridge && window.FlutterBridge.receiveFromFlutter) {
              window.FlutterBridge.receiveFromFlutter({
                type: 'DRIVER_SET',
                driverId: '$driverId',
                timestamp: new Date().toISOString()
              });
            }
          """
        );
        
        print('✅ Driver ID sent to PWA');
        
      } catch (e) {
        print('❌ Error notifying PWA: $e');
      }
    });
  }

  void _startStatusSyncWithPWA() {
    // إلغاء أي timer سابق
    statusSyncTimer?.cancel();
    
    // بدء مزامنة جديدة كل 5 ثواني
    statusSyncTimer = Timer.periodic(const Duration(seconds: 5), (timer) async {
      if (web == null || driverId == null) return;
      
      try {
        // قراءة حالة السائق من PWA
        final result = await web!.evaluateJavascript(source: """
          (function() {
            try {
              var status = localStorage.getItem('driver_status');
              var isOnline = localStorage.getItem('driver_forever_online') === 'true';
              var driverId = localStorage.getItem('driver_id');
              
              return JSON.stringify({
                driverId: driverId,
                isOnline: isOnline,
                status: status,
                timestamp: new Date().toISOString()
              });
            } catch(e) {
              return 'error:' + e.message;
            }
          })();
        """);
        
        if (result != null && result.toString().startsWith('{')) {
          final data = jsonDecode(result.toString());
          print('🔄 Driver status from PWA: $data');
          
          // تحديث الحالة في Supabase إذا كانت مختلفة
          if (data['driverId'] == driverId) {
            await _updateDriverStatusInSupabase(data['isOnline'] == true);
          }
        }
        
      } catch (e) {
        print('❌ Error syncing status: $e');
      }
    });
  }

  Future<void> _updateDriverStatusInSupabase(bool isOnline) async {
    try {
      await supabase.from('driver_locations').upsert({
        'driver_id': driverId,
        'is_online': isOnline,
        'last_seen': DateTime.now().toIso8601String(),
        'updated_at': DateTime.now().toIso8601String(),
      });
      print('📡 Driver status updated in Supabase: ${isOnline ? 'Online' : 'Offline'}');
    } catch (e) {
      print('❌ Error updating driver status: $e');
    }
  }

  void _setupWebViewMessageHandlers() {
    // إعداد معالجين للرسائل من JavaScript
    
    // معالج لطلبات تغيير حالة السائق
    web?.addJavaScriptHandler(
      handlerName: 'driverStatusChange',
      callback: (args) async {
        final data = args[0] as Map<String, dynamic>;
        print('🔄 Driver status change request: $data');
        
        if (data['driverId'] == driverId) {
          await _updateDriverStatusInSupabase(data['online'] == true);
        }
      },
    );
    
    // معالج لتسجيل الدخول
    web?.addJavaScriptHandler(
      handlerName: 'driverLogin',
      callback: (args) async {
        final data = args[0] as Map<String, dynamic>;
        print('👤 Driver login from PWA: $data');
        
        if (data['driverId'] != null && data['driverId'] != driverId) {
          await _saveDriver(data['driverId'].toString());
        }
      },
    );
    
    // معالج للرسائل العامة
    web?.addJavaScriptHandler(
      handlerName: 'messageHandler',
      callback: (args) {
        final message = args[0] as Map<String, dynamic>;
        print('📨 Message from PWA: $message');
        
        // معالجة أنواع مختلفة من الرسائل
        switch (message['type']) {
          case 'CONNECTION_TEST':
            print('✅ Connection test received from PWA');
            break;
          case 'PWA_READY':
            print('✅ PWA is ready and listening');
            break;
        }
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('زونا للسائقين'),
        backgroundColor: Colors.green[700],
      ),
      body: InAppWebView(
        initialUrlRequest:
            URLRequest(url: WebUri('https://driver.zoonasd.com/')),
        initialSettings: InAppWebViewSettings(
          javaScriptEnabled: true,
          domStorageEnabled: true,
          mediaPlaybackRequiresUserGesture: false,
          javaScriptCanOpenWindowsAutomatically: true,
          supportMultipleWindows: true,
          clearSessionCache: false,
          cacheEnabled: true,
        ),
        onWebViewCreated: (controller) {
          web = controller;
          print('🌐 WebView created');
          
          // إعداد معالجي الرسائل بعد إنشاء WebView
          _setupWebViewMessageHandlers();
        },
        onLoadStart: (controller, url) {
          print('🔗 Loading: $url');
        },
        onLoadStop: (controller, url) async {
          print('✅ Page loaded: $url');
          
          // بدء مزامنة السائق بعد تحميل الصفحة
          _startDriverSync();
          
          // إعادة إرسال driver_id إذا كان موجوداً
          if (driverId != null) {
            _notifyPWAOfDriver(driverId!);
          }
        },
        onLoadError: (controller, url, code, message) {
          print('❌ Load error ($code): $message');
        },
        onConsoleMessage: (controller, consoleMessage) {
          print('📝 Console [${consoleMessage.messageLevel}]: ${consoleMessage.message}');
        },
        shouldOverrideUrlLoading: (controller, nav) async {
          final uri = nav.request.url!;
          print('🔗 URL request: ${uri.toString()}');
          
          // السماح بجميع روابط http/https
          if (['http', 'https'].contains(uri.scheme)) {
            return NavigationActionPolicy.ALLOW;
          }
          
          // فتح الروابط الخارجية في متصفح خارجي
          if (await canLaunchUrl(uri)) {
            await launchUrl(uri);
          }
          return NavigationActionPolicy.CANCEL;
        },
      ),
      // زر إضافي لاختبار الإشعارات يدوياً
      floatingActionButton: FloatingActionButton(
        onPressed: _sendTestNotification,
        backgroundColor: Colors.green,
        child: const Icon(Icons.notifications),
      ),
    );
  }

  Future<void> _sendTestNotification() async {
    print('🧪 Sending test notification...');
    
    final testData = {
      'type': 'ride_request',
      'rideId': 'test_${DateTime.now().millisecondsSinceEpoch}',
      'requestId': 'req_test_${DateTime.now().millisecondsSinceEpoch}',
      'customerName': 'عميل تجريبي',
      'customerPhone': '0912345678',
      'vehicleType': 'economy',
      'amount': '5000',
      'distance': '3.5 كم',
      'pickupAddress': 'موقع تجريبي',
      'destinationAddress': 'وجهة تجريبية',
      'timestamp': DateTime.now().toIso8601String(),
    };
    
    await _playNotificationSound();
    await _showLocalNotification(testData);
    await _sendToPWA(testData);
  }

  void _startDriverSync() {
    // مزامنة متقدمة كل 3 ثواني
    Timer.periodic(const Duration(seconds: 3), (timer) async {
      if (web == null) return;

      try {
        // قراءة driver_id من localStorage
        final result = await web!.evaluateJavascript(source: """
          (function() {
            try {
              var driverId = localStorage.getItem('driver_id') || 
                            localStorage.getItem('tarhal_driver_id');
              var driverData = localStorage.getItem('tarhal_driver');
              
              if (driverData) {
                var parsed = JSON.parse(driverData);
                driverId = parsed.id || driverId;
              }
              
              return driverId || 'null';
            } catch(e) {
              return 'error:' + e.message;
            }
          })();
        """);

        print('🔍 Driver sync result: $result');

        if (result != null && result != 'null' && !result.toString().startsWith('error:')) {
          final id = result.toString();
          
          if (id.length > 5 && id != driverId) {
            print('🆕 New driver ID detected: $id');
            await _saveDriver(id);
          } else if (id == driverId) {
            print('✅ Driver ID already synchronized');
          }
        }
        
        // قراءة حالة السائق أيضاً
        await web!.evaluateJavascript(source: """
          if (window.checkFlutterConnection) {
            window.checkFlutterConnection();
          }
        """);
        
      } catch (e) {
        print('❌ Driver sync error: $e');
      }
    });
  }

  @override
  void dispose() {
    channel?.unsubscribe();
    statusSyncTimer?.cancel();
    super.dispose();
  }
}