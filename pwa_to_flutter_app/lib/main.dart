import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'; 
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart' as fln;
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'constants.dart';

@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  // If the message contains a notification object, the Android system will
  // automatically display it when the app is in the background.
  // We only need to show a local notification here if it's a data-only message.
  if (message.notification == null) {
    await Firebase.initializeApp();
    final fln.FlutterLocalNotificationsPlugin notifications = fln.FlutterLocalNotificationsPlugin();
    const android = fln.AndroidInitializationSettings('@mipmap/ic_launcher');
    await notifications.initialize(const fln.InitializationSettings(android: android));

    String title = message.data['title'] ?? 'متجر زونا';
    String body = message.data['body'] ?? 'لديك إشعار جديد';

    await notifications.show(
      message.hashCode, title, body,
      const fln.NotificationDetails(
        android: fln.AndroidNotificationDetails(
          'default_notification_channel',
          'إشعارات متجر زونا',
          importance: fln.Importance.high,
          priority: fln.Priority.high,
          playSound: true,
          enableVibration: true,
          channelShowBadge: true,
          visibility: fln.NotificationVisibility.public,
        ),
      ),
      payload: jsonEncode(message.data),
    );
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  
  await Firebase.initializeApp();
  FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);

  if (kDebugMode && !kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
    await InAppWebViewController.setWebContentsDebuggingEnabled(true);
  }

  // Requesting necessary permissions
  await [Permission.notification, Permission.camera].request();

  runApp(const ZoonaApp());
}

class ZoonaApp extends StatelessWidget {
  const ZoonaApp({super.key});
  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      title: 'متجر زونا',
      debugShowCheckedModeBanner: false,
      home: ZoonaHome()
    );
  }
}

class ZoonaHome extends StatefulWidget {
  const ZoonaHome({super.key});
  @override
  State<ZoonaHome> createState() => _ZoonaHomeState();
}

class _ZoonaHomeState extends State<ZoonaHome> {
  final fln.FlutterLocalNotificationsPlugin notifications = fln.FlutterLocalNotificationsPlugin();
  InAppWebViewController? web;
  bool _isPageLoaded = false;
  String? fcmToken;
  String? _pendingUrl;
  StreamSubscription<RemoteMessage>? _onMessageSubscription;

  @override
  void initState() {
    super.initState();
    _initNotifications();
    _initFirebaseMessaging();
  }

  Future<void> _initNotifications() async {
    const androidInit = fln.AndroidInitializationSettings('@mipmap/ic_launcher');
    await notifications.initialize(const fln.InitializationSettings(android: androidInit),
      onDidReceiveNotificationResponse: (details) {
        if (details.payload != null) {
          _handleNotificationClick(jsonDecode(details.payload!));
        }
      }
    );

    final androidImplementation = notifications.resolvePlatformSpecificImplementation<fln.AndroidFlutterLocalNotificationsPlugin>();

    const channel = fln.AndroidNotificationChannel(
      'default_notification_channel',
      'إشعارات متجر زونا',
      description: 'قناة إشعارات متجر زونا العامة',
      importance: fln.Importance.high,
      playSound: true,
      enableVibration: true,
    );
    await androidImplementation?.createNotificationChannel(channel);
  }

  Future<void> _initFirebaseMessaging() async {
    FirebaseMessaging messaging = FirebaseMessaging.instance;

    // Request permission for iOS/Android
    NotificationSettings settings = await messaging.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );

    if (settings.authorizationStatus == AuthorizationStatus.authorized) {
      fcmToken = await messaging.getToken();
      if (fcmToken != null) _sendTokenToPWA(fcmToken!);
    }

    messaging.onTokenRefresh.listen((newToken) {
      fcmToken = newToken;
      _sendTokenToPWA(newToken);
    });

    FirebaseMessaging.onMessageOpenedApp.listen((message) => _handleNotificationClick(message.data));

    messaging.getInitialMessage().then((message) {
      if (message != null) _handleNotificationClick(message.data);
    });

    _onMessageSubscription = FirebaseMessaging.onMessage.listen((message) {
      _showLocalNotification(message);
    });
  }

  void _handleNotificationClick(Map<String, dynamic> data) {
    final String? url = data['url']?.toString() ?? data['link']?.toString();

    if (url != null && url.isNotEmpty) {
      if (web != null) {
        web!.loadUrl(urlRequest: URLRequest(url: WebUri(url)));
      } else {
        setState(() => _pendingUrl = url);
      }
    }
  }

  Future<void> _showLocalNotification(RemoteMessage message) async {
    RemoteNotification? notification = message.notification;
    AndroidNotification? android = message.notification?.android;

    // In foreground, we always show a local notification because the system doesn't.
    await notifications.show(
      message.hashCode,
      notification?.title ?? message.data['title'] ?? 'متجر زونا',
      notification?.body ?? message.data['body'] ?? 'لديك إشعار جديد',
      fln.NotificationDetails(
        android: fln.AndroidNotificationDetails(
          'default_notification_channel',
          'إشعارات متجر زونا',
          importance: fln.Importance.high,
          priority: fln.Priority.high,
          icon: android?.smallIcon ?? '@mipmap/ic_launcher',
        ),
      ),
      payload: jsonEncode(message.data),
    );
  }

  void _sendTokenToPWA(String token) async {
    if (web != null && _isPageLoaded) {
      await web!.evaluateJavascript(source: "if(typeof window.setFCMToken === 'function') window.setFCMToken('$token');");
    }
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
            initialUrlRequest: URLRequest(
              url: WebUri(_pendingUrl ?? kPwaUri.toString()),
              headers: {'Accept-Language': 'en-US,en;q=0.9'},
            ),
            initialUserScripts: UnmodifiableListView<UserScript>([
              UserScript(
                source: """
                  (function() {
                    // Force en-US locale for toLocaleString
                    const originalToLocaleString = Number.prototype.toLocaleString;
                    Number.prototype.toLocaleString = function(locales, options) {
                      return originalToLocaleString.call(this, 'en-US', options);
                    };

                    // Force en-US locale for Intl.NumberFormat
                    if (window.Intl && Intl.NumberFormat) {
                      const OriginalNumberFormat = Intl.NumberFormat;
                      Intl.NumberFormat = function(locales, options) {
                        return new OriginalNumberFormat('en-US', options);
                      };
                      Intl.NumberFormat.prototype = OriginalNumberFormat.prototype;
                      Intl.NumberFormat.supportedLocalesOf = OriginalNumberFormat.supportedLocalesOf;
                    }
                  })();
                """,
                injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
              ),
            ]),
            initialSettings: InAppWebViewSettings(
              javaScriptEnabled: true,
              domStorageEnabled: true,
              geolocationEnabled: true,
              useShouldOverrideUrlLoading: true,
              userAgent: "Mozilla/5.0 (Linux; Android 13; en-US) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/116.0.0.0 Mobile Safari/537.36",
            ),
            onWebViewCreated: (controller) {
              web = controller;
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
                await prefs.setString('last_url', currentUrl);
              }
              if (fcmToken != null) _sendTokenToPWA(fcmToken!);
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

  @override
  void dispose() {
    _onMessageSubscription?.cancel();
    super.dispose();
  }
}
