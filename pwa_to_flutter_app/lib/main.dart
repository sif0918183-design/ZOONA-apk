import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:onesignal_flutter/onesignal_flutter.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:vibration/vibration.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await initializeOneSignal();

  if (Platform.isAndroid) {
    await InAppWebViewController.setWebContentsDebuggingEnabled(kDebugMode);
  }

  runApp(const MyApp());
}

Future<void> initializeOneSignal() async {
  await OneSignal.shared.setAppId(
    "c05c5d16-4e72-4d4a-b1a2-6e7e06232d98",
  );

  await OneSignal.shared.promptUserForPushNotificationPermission();
}

class MyApp extends StatefulWidget {
  const MyApp({Key? key}) : super(key: key);

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> with WidgetsBindingObserver {
  final GlobalKey webViewKey = GlobalKey();
  InAppWebViewController? webViewController;
  final AudioPlayer audioPlayer = AudioPlayer();
  PullToRefreshController? pullToRefreshController;

  bool _isLoading = true;
  String _currentUrl = '';
  late ConnectivityResult _connectivityStatus;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initApp();
  }

  Future<void> _initApp() async {
    await _setupOneSignalListeners();

    _connectivityStatus = await Connectivity().checkConnectivity();
    Connectivity().onConnectivityChanged.listen((result) {
      setState(() {
        _connectivityStatus = result;
      });
    });

    pullToRefreshController = PullToRefreshController(
      settings: PullToRefreshSettings(color: Colors.blue),
      onRefresh: () async {
        await webViewController?.reload();
      },
    );

    await audioPlayer.setSource(
      AssetSource('ride_request_sound.wav'),
    );
  }

  Future<void> _setupOneSignalListeners() async {
    // وصول الإشعار
    OneSignal.shared
        .setNotificationWillShowInForegroundHandler((event) async {
      await _playNotificationSound();
      await _vibrateDevice();
      event.complete(event.notification);
    });

    // الضغط على الإشعار
    OneSignal.shared
        .setNotificationOpenedHandler((openedResult) async {
      await _playNotificationSound();
      await _vibrateDevice();

      final data =
          openedResult.notification.additionalData ?? {};

      final rideId = data['rideId']?.toString() ?? '';
      final requestId = data['requestId']?.toString() ?? '';

      if (rideId.isNotEmpty && requestId.isNotEmpty) {
        final url =
            "https://driver.zoonasd.com/accept-ride.html?rideId=$rideId&requestId=$requestId";
        _loadRideUrl(url);
      }
    });
  }

  Future<void> _playNotificationSound() async {
    await audioPlayer.stop();
    await audioPlayer.play(
      AssetSource('ride_request_sound.wav'),
    );
  }

  Future<void> _vibrateDevice() async {
    if (await Vibration.hasVibrator() ?? false) {
      await Vibration.vibrate(
        pattern: [500, 250, 500],
      );
    }
  }

  void _loadRideUrl(String url) {
    if (webViewController != null) {
      webViewController!.loadUrl(
        urlRequest: URLRequest(url: WebUri(url)),
      );
    } else {
      _currentUrl = url;
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'ترحال زونا - السائق',
      home: Scaffold(
        body: Stack(
          children: [
            _buildWebView(),
            if (_isLoading)
              const Center(child: CircularProgressIndicator()),
          ],
        ),
      ),
    );
  }

  Widget _buildWebView() {
    return InAppWebView(
      key: webViewKey,
      initialUrlRequest: URLRequest(
        url: WebUri(
          _currentUrl.isNotEmpty
              ? _currentUrl
              : "https://driver.zoonasd.com/",
        ),
      ),
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        useHybridComposition: true,
        domStorageEnabled: true,
      ),
      pullToRefreshController: pullToRefreshController,
      onWebViewCreated: (controller) {
        webViewController = controller;
      },
      onLoadStart: (_, __) {
        setState(() => _isLoading = true);
      },
      onLoadStop: (controller, url) async {
        setState(() => _isLoading = false);

        if (url != null &&
            url.queryParameters.containsKey('driver_id')) {
          final driverId = url.queryParameters['driver_id'];
          if (driverId != null) {
            await OneSignal.shared
                .setExternalUserId(driverId);

            final prefs =
                await SharedPreferences.getInstance();
            await prefs.setString('driver_id', driverId);
          }
        }
      },
      shouldOverrideUrlLoading:
          (controller, navigationAction) async {
        final uri = navigationAction.request.url;
        if (uri == null) return NavigationActionPolicy.ALLOW;

        if (uri.host != "driver.zoonasd.com") {
          await launchUrl(
            uri,
            mode: LaunchMode.externalApplication,
          );
          return NavigationActionPolicy.CANCEL;
        }
        return NavigationActionPolicy.ALLOW;
      },
    );
  }
}