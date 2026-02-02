import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:onesignal_flutter/onesignal_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Supabase.initialize(
    url: 'https://zsmlyiygjagmhnglrhoa.supabase.co',
    anonKey: 'YOUR_SUPABASE_ANON_KEY',
  );

  await OneSignal.shared.setAppId(
    "c05c5d16-4e72-4d4a-b1a2-6e7e06232d98",
  );

  if (Platform.isAndroid) {
    await InAppWebViewController.setWebContentsDebuggingEnabled(kDebugMode);
  }

  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});
  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  InAppWebViewController? controller;
  bool isLoading = true;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: SafeArea(
          child: Stack(
            children: [
              InAppWebView(
                initialUrlRequest: URLRequest(
                  url: WebUri("https://driver.zoonasd.com/"),
                ),
                onWebViewCreated: (c) => controller = c,
                onLoadStop: (c, _) async {
                  setState(() => isLoading = false);

                  await Future.delayed(const Duration(seconds: 2));
                  await syncDriverWithPushToken(c);
                },
              ),
              if (isLoading)
                const Center(child: CircularProgressIndicator()),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> syncDriverWithPushToken(InAppWebViewController c) async {
    try {
      // قراءة driver_id من PWA
      final driverId = await c.evaluateJavascript(source: """
        localStorage.getItem('driver_id') ||
        localStorage.getItem('tarhal_driver_id');
      """);

      if (driverId == null || driverId.toString().length < 5) {
        debugPrint("⏳ driver_id not found");
        return;
      }

      // جلب push token من OneSignal
      final deviceState = await OneSignal.shared.getDeviceState();
      final pushToken = deviceState?.userId;

      if (pushToken == null) {
        debugPrint("❌ push token not found");
        return;
      }

      debugPrint("✅ driver_id: $driverId");
      debugPrint("✅ push_token: $pushToken");

      // تحديث قاعدة البيانات مباشرة
      await Supabase.instance.client
          .from('drivers')
          .update({'push_token': pushToken}).eq('id', driverId);

      debugPrint("🚀 Driver linked with push token successfully");
    } catch (e) {
      debugPrint("Sync error: $e");
    }
  }
}