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
import 'package:location/location.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // تهيئة Supabase
  await Supabase.initialize(
    url: 'https://zsmlyiygjagmhnglrhoa.supabase.co',
    anonKey:
        'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InpzbWx5aXlnamFnbWhuZ2xyaG9hIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NjU5NDc3NjMsImV4cCI6MjA4MTUyMzc2M30.QviVinAng-ILq0umvI5UZCFEvNpP3nI0kW_hSaXxNps',
  );

  // طلب أذونات الموقع والإشعارات
  await [
    Permission.notification,
    Permission.location,
    Permission.locationAlways,
  ].request();

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

    _listenForRides();
    _notifyPWAOfDriver(id);
  }

  void _listenForRides() {
    print('🎯 Setting up Realtime listener for driver: $driverId');

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

            if (rideData.isEmpty) return;

            await _playNotificationSound();
            await _showLocalNotification(rideData);
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
      await audioPlayer.setSource(AssetSource('ride_request_sound.wav'));
      await audioPlayer.play(AssetSource('ride_request_sound.wav'));

      if (await Vibration.hasVibrator() ?? false) {
        Vibration.vibrate(pattern: [500, 200, 500]);
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
    } catch (e) {
      print('❌ Error showing notification: $e');
    }
  }

  Future<void> _sendToPWA(Map<String, dynamic> data) async {
    if (web == null) return;
    try {
      final jsonStr = jsonEncode(data);
      await web!.evaluateJavascript(
        source: """
          if (typeof handleRideRequest === 'function') {
            handleRideRequest($jsonStr);
          }
          localStorage.setItem('last_ride_from_flutter', $jsonStr);
        """
      );
    } catch (e) {
      print('❌ Error sending to PWA: $e');
    }
  }

  void _notifyPWAOfDriver(String driverId) {
    if (web == null) return;
    Timer(const Duration(milliseconds: 500), () async {
      try {
        await web!.evaluateJavascript(
          source: """
            localStorage.setItem('driver_id', '$driverId');
            localStorage.setItem('tarhal_driver_id', '$driverId');
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
      if (web == null || driverId == null) return;

      try {
        final result = await web!.evaluateJavascript(source: """
          (function() {
            try {
              var isOnline = localStorage.getItem('driver_forever_online') === 'true';
              return JSON.stringify({ isOnline: isOnline });
            } catch(e) {
              return 'error:' + e.message;
            }
          })();
        """);

        if (result != null && !result.toString().startsWith('error:')) {
          final data = jsonDecode(result.toString());
          await _updateDriverStatusInSupabase(data['isOnline'] == true);
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
    } catch (e) {
      print('❌ Error updating driver status: $e');
    }
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
        ),
        onWebViewCreated: (controller) {
          web = controller;
        },
        onLoadStop: (controller, url) {
          _startDriverSync();
          if (driverId != null) _notifyPWAOfDriver(driverId!);
        },
        shouldOverrideUrlLoading: (controller, nav) async {
          final uri = nav.request.url!;
          if (['http', 'https'].contains(uri.scheme)) return NavigationActionPolicy.ALLOW;
          if (await canLaunchUrl(uri)) await launchUrl(uri);
          return NavigationActionPolicy.CANCEL;
        },
      ),
    );
  }

  void _startDriverSync() {
    Timer.periodic(const Duration(seconds: 3), (timer) async {
      if (web == null) return;
      try {
        final result = await web!.evaluateJavascript(source: """
          (function() {
            try {
              return localStorage.getItem('driver_id') || 'null';
            } catch(e) { return 'error:' + e.message; }
          })();
        """);

        if (result != null && result != 'null' && !result.toString().startsWith('error:')) {
          final id = result.toString();
          if (id.length > 5 && id != driverId) await _saveDriver(id);
        }
      } catch (_) {}
    });
  }

  @override
  void dispose() {
    channel?.unsubscribe();
    statusSyncTimer?.cancel();
    super.dispose();
  }
}