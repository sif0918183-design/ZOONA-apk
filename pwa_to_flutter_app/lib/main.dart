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
    if (driverId != null) {
      _listenForRides();
    }
  }

  Future<void> _saveDriver(String id) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('driver_id', id);
    driverId = id;
    _listenForRides();
  }

  void _listenForRides() {
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
        callback: (payload) {
          final data = payload.newRecord;
          _handleRide(data);
        },
      )
      ..subscribe();
  }

  Future<void> _handleRide(Map<String, dynamic> data) async {
    // صوت + اهتزاز
    if (await Vibration.hasVibrator() ?? false) {
      Vibration.vibrate(pattern: [500, 200, 500]);
    }
    await audioPlayer.play(AssetSource('ride_request_sound.wav'));

    // إشعار
    await notifications.show(
      0,
      'طلب رحلة جديد',
      'اضغط لعرض التفاصيل',
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'rides',
          'Ride Requests',
          importance: Importance.max,
          priority: Priority.high,
        ),
      ),
    );

    // إرسال للـ PWA
    final jsonStr = jsonEncode(data);
    await web?.evaluateJavascript(
      source: "window.handleRideRequest($jsonStr);",
    );
  }

  void _startDriverSync() {
    Timer.periodic(const Duration(seconds: 3), (timer) async {
      if (web == null) return;

      final result = await web!.evaluateJavascript(source: """
        localStorage.getItem('driver_id');
      """);

      if (result != null && result.toString().length > 10) {
        final id = result.toString().replaceAll('"', '');
        if (id != driverId) {
          await _saveDriver(id);
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: InAppWebView(
        initialUrlRequest:
            URLRequest(url: WebUri('https://driver.zoonasd.com/')),
        initialSettings: InAppWebViewSettings(
          javaScriptEnabled: true,
          domStorageEnabled: true,
          mediaPlaybackRequiresUserGesture: false,
        ),
        onWebViewCreated: (controller) {
          web = controller;
        },
        onLoadStop: (controller, url) {
          _startDriverSync();
        },
        shouldOverrideUrlLoading: (controller, nav) async {
          final uri = nav.request.url!;
          if (!['http', 'https'].contains(uri.scheme)) {
            if (await canLaunchUrl(uri)) {
              await launchUrl(uri);
            }
            return NavigationActionPolicy.CANCEL;
          }
          return NavigationActionPolicy.ALLOW;
        },
      ),
    );
  }
}