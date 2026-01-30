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
  
  // تهيئة OneSignal
  initializeOneSignal();
  
  // تهيئة WebView
  if (Platform.isAndroid) {
    await InAppWebViewController.setWebContentsDebuggingEnabled(kDebugMode);
  }
  
  runApp(const MyApp());
}

void initializeOneSignal() {
  OneSignal.shared.init(
    "c05c5d16-4e72-4d4a-b1a2-6e7e06232d98",
    iOSSettings: {
      OSiOSSettings.autoPrompt: true,
      OSiOSSettings.inAppLaunchUrl: false
    },
  );

  // تفعيل الاشتراك
  OneSignal.shared.setSubscription(true);

  // منح الموافقة على الخصوصية
  OneSignal.shared.consentGranted(true);

  // إعدادات Logging
  OneSignal.shared.setLogLevel(OSLogLevel.verbose, OSLogLevel.none);
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
    // إعداد OneSignal Listeners
    _setupOneSignalListeners();
    
    // التحقق من الاتصال
    _connectivityStatus = await Connectivity().checkConnectivity();
    Connectivity().onConnectivityChanged.listen((result) {
      setState(() {
        _connectivityStatus = result;
      });
    });
    
    // إعداد WebView
    pullToRefreshController = PullToRefreshController(
      settings: PullToRefreshSettings(
        color: Colors.blue,
      ),
      onRefresh: () async {
        if (webViewController != null) {
          await webViewController!.reload();
        }
      },
    );
    
    // تحميل الصوت مسبقاً
    try {
      await audioPlayer.setSource(AssetSource('ride_request_sound.wav'));
    } catch (e) {
      debugPrint("Error loading sound: $e");
    }
  }

  void _setupOneSignalListeners() {
    // عند استقبال الإشعار
    OneSignal.shared.setNotificationReceivedHandler((notification) {
      debugPrint("🎯 Notification received: ${notification.jsonRepresentation().replaceAll("\\n", "")}");
      _playNotificationSound();
      _vibrateDevice();
    });

    // عند فتح الإشعار
    OneSignal.shared.setNotificationOpenedHandler((result) {
      debugPrint("👆 Notification clicked: ${result.notification.jsonRepresentation()}");
      _playNotificationSound();
      _vibrateDevice();

      final data = result.notification.payload.additionalData ?? {};
      final rideId = data['rideId']?.toString() ?? '';
      final requestId = data['requestId']?.toString() ?? '';
      
      if (rideId.isNotEmpty && requestId.isNotEmpty) {
        final acceptUrl = 
            "https://driver.zoonasd.com/accept-ride.html?rideId=$rideId&requestId=$requestId";
        _loadRideUrl(acceptUrl);
      }
    });
  }

  Future<void> _playNotificationSound() async {
    try {
      await audioPlayer.stop();
      await audioPlayer.play(AssetSource('ride_request_sound.wav'));
      await audioPlayer.setVolume(1.0);
      debugPrint("🔊 Notification sound played");
    } catch (e) {
      debugPrint("Error playing sound: $e");
    }
  }

  Future<void> _vibrateDevice() async {
    try {
      if (await Vibration.hasVibrator() ?? false) {
        await Vibration.vibrate(pattern: [500, 250, 500], intensities: [255, 128, 255]);
        debugPrint("📳 Device vibrated");
      }
    } catch (e) {
      debugPrint("Error vibrating: $e");
    }
  }

  void _loadRideUrl(String url) {
    if (webViewController != null) {
      webViewController!.loadUrl(urlRequest: URLRequest(url: WebUri(url)));
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        setState(() {
          _currentUrl = url;
        });
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (!kIsWeb && webViewController != null) {
      if (state == AppLifecycleState.paused) {
        webViewController?.pause();
        webViewController?.pauseTimers();
      } else if (state == AppLifecycleState.resumed) {
        webViewController?.resume();
        webViewController?.resumeTimers();
      }
    }
  }

  @override
  void dispose() {
    audioPlayer.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvoked: (didPop) async {
        if (didPop) return;
        final controller = webViewController;
        if (controller != null && await controller.canGoBack()) {
          controller.goBack();
        } else {
          SystemNavigator.pop();
        }
      },
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'ترحال زونا - السائق',
        theme: ThemeData(
          primarySwatch: Colors.blue,
          useMaterial3: true,
        ),
        home: Scaffold(
          appBar: AppBar(toolbarHeight: 0, backgroundColor: const Color(0xFF4F46E5), elevation: 0),
          body: _buildBody(),
        ),
      ),
    );
  }

  Widget _buildBody() {
    return Stack(
      children: [
        _buildWebView(),
        if (_isLoading)
          Container(
            color: Colors.white,
            child: const Center(
              child: CircularProgressIndicator(color: Color(0xFF4F46E5)),
            ),
          ),
        if (_connectivityStatus == ConnectivityResult.none)
          Container(
            color: Colors.black54,
            child: Center(
              child: Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12)),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.wifi_off, size: 50, color: Colors.red),
                    const SizedBox(height: 16),
                    const Text('لا يوجد اتصال بالإنترنت', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 16),
                    ElevatedButton(
                      onPressed: () {
                        if (webViewController != null) {
                          webViewController!.reload();
                        }
                      },
                      style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF4F46E5)),
                      child: const Text('إعادة المحاولة', style: TextStyle(fontWeight: FontWeight.bold)),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildWebView() {
    return InAppWebView(
      key: webViewKey,
      initialUrlRequest: URLRequest(url: WebUri(_currentUrl.isNotEmpty ? _currentUrl : "https://driver.zoonasd.com/")),
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        useHybridComposition: true,
        cacheMode: CacheMode.LOAD_DEFAULT,
        domStorageEnabled: true,
        databaseEnabled: true,
        mediaPlaybackRequiresUserGesture: false,
        allowsInlineMediaPlayback: true,
        mixedContentMode: MixedContentMode.MIXED_CONTENT_ALWAYS_ALLOW,
        safeBrowsingEnabled: true,
      ),
      pullToRefreshController: pullToRefreshController,
      onWebViewCreated: (controller) {
        webViewController = controller;
      },
      onLoadStart: (controller, url) {
        setState(() => _isLoading = true);
      },
      onLoadStop: (controller, url) async {
        setState(() {
          _isLoading = false;
          _currentUrl = url?.toString() ?? '';
        });

        if (url != null && url.queryParameters.containsKey('driver_id')) {
          final driverId = url.queryParameters['driver_id'];
          if (driverId != null && driverId.isNotEmpty) {
            // لا يوجد setExternalUserId في 3.2.7
            final prefs = await SharedPreferences.getInstance();
            await prefs.setString('driver_id', driverId);
          }
        }
      },
    );
  }
}