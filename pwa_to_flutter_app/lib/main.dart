import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:onesignal_flutter/onesignal_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:google_fonts/google_fonts.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 1. تهيئة Supabase
  await Supabase.initialize(
    url: 'https://zsmlyiygjagmhnglrhoa.supabase.co',
    anonKey: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InpzbWx5aXlnamFnbWhuZ2xyaG9hIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NjU5NDc3NjMsImV4cCI6MjA4MTUyMzc2M30.QviVinAng-ILq0umvI5UZCFEvNpP3nI0kW_hSaXxNps',
  );

  // 2. تهيئة OneSignal مع إعدادات الصوت
  await initOneSignal();

  if (Platform.isAndroid) {
    await InAppWebViewController.setWebContentsDebuggingEnabled(kDebugMode);
  }

  runApp(const TarhalZoonaDriverApp());
}

Future<void> initOneSignal() async {
  // إعداد مستوى سجل الأخطاء
  OneSignal.shared.setLogLevel(OSLogLevel.verbose, OSLogLevel.none);

  // وضع معرف التطبيق الخاص بك
  await OneSignal.shared.setAppId('c05c5d16-4e72-4d4a-b1a2-6e7e06232d98');

  // طلب إذن الإشعارات
  OneSignal.shared.promptUserForPushNotificationPermission().then((accepted) {
    debugPrint("Accepted permission: $accepted");
  });

  // إعداد كيفية ظهور الإشعارات والتفاعل معها
  OneSignal.shared.setNotificationWillShowInForegroundHandler((OSNotificationReceivedEvent event) {
    // تشغيل الصوت المخصص عند استلام إشعار والتطبيق مفتوح
    event.complete(event.notification);
  });
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
        // تطبيق خط تجول عالمياً عبر مكتبة جوجل
        textTheme: GoogleFonts.tajawalTextTheme(Theme.of(context).textTheme),
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

class _DriverHomeScreenState extends State<DriverHomeScreen> {
  InAppWebViewController? _webViewController;
  bool _isLoading = true;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Stack(
          children: [
            InAppWebView(
              initialUrlRequest: URLRequest(
                url: WebUri("https://driver.zoonasd.com/"),
              ),
              initialSettings: InAppWebViewSettings(
                javaScriptEnabled: true,
                domStorageEnabled: true,
                supportZoom: false,
              ),
              onWebViewCreated: (controller) => _webViewController = controller,
              onLoadStop: (controller, url) {
                setState(() => _isLoading = false);
              },
              onReceivedError: (controller, request, error) {
                debugPrint("WebView Error: ${error.description}");
              },
            ),
            if (_isLoading)
              const Center(
                child: CircularProgressIndicator(color: Color(0xFF4f46e5)),
              ),
          ],
        ),
      ),
    );
  }
}
