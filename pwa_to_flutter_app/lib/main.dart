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
  
  // تهيئة OneSignal أولاً وقبل كل شيء
  await initializeOneSignal();
  
  // تهيئة WebView
  if (Platform.isAndroid) {
    await InAppWebViewController.setWebContentsDebuggingEnabled(kDebugMode);
  }
  
  runApp(const MyApp());
}

Future<void> initializeOneSignal() async {
  // تهيئة OneSignal مع الإعدادات المتقدمة
  OneSignal.Debug.setLogLevel(OSLogLevel.verbose);
  
  await OneSignal.shared.setAppId("c05c5d16-4e72-4d4a-b1a2-6e7e06232d98");
  
  // إعدادات متقدمة
  await OneSignal.shared.setRequiresUserPrivacyConsent(false);
  await OneSignal.shared.consentGranted(true);
  
  // تفعيل جميع الميزات
  await OneSignal.shared.disablePush(false);
  await OneSignal.shared.disableSound(false);
  await OneSignal.shared.disableVibrate(false);
  
  // طلب الأذونات
  await OneSignal.shared.promptUserForPushNotificationPermission(
    fallbackToSettings: true,
  );
  
  // إعدادات الإشعارات في الخلفية
  await OneSignal.shared.setLocationShared(true);
  await OneSignal.shared.setSubscription(true);
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
    await _setupOneSignalListeners();
    
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

  Future<void> _setupOneSignalListeners() async {
    final oneSignal = OneSignal.shared;
    
    // 1. عندما يصل الإشعار (حتى في الخلفية)
    oneSignal.setNotificationWillShowInForegroundHandler((event) async {
      debugPrint("🎯 Notification received in foreground/background");
      
      // تشغيل الصوت
      await _playNotificationSound();
      
      // الاهتزاز
      await _vibrateDevice();
      
      // إكمال العرض
      event.complete(event.notification);
    });
    
    // 2. عندما ينقر على الإشعار
    oneSignal.setNotificationOpenedHandler((openedResult) async {
      debugPrint("👆 Notification clicked");
      
      // صوت واهتزاز إضافي
      await _playNotificationSound();
      await _vibrateDevice();
      
      // معالجة البيانات
      final data = openedResult.notification.additionalData;
      final rideId = data?['rideId']?.toString() ?? '';
      final requestId = data?['requestId']?.toString() ?? '';
      
      if (rideId.isNotEmpty && requestId.isNotEmpty) {
        final acceptUrl = 
            "https://driver.zoonasd.com/accept-ride.html?rideId=$rideId&requestId=$requestId";
        
        // تحميل URL في WebView
        _loadRideUrl(acceptUrl);
      }
    });
    
    // 3. معالج رفض الإشعارات
    oneSignal.setPermissionObserver((state) {
      debugPrint("🔔 Permission state: ${state.toJson()}");
    });
    
    // 4. معالج التغييرات في Subscription
    oneSignal.setSubscriptionObserver((changes) async {
      debugPrint("📱 Subscription changed: ${changes.toJson()}");
      
      // حفظ Device ID في SharedPreferences
      final deviceState = await oneSignal.getDeviceState();
      if (deviceState?.userId != null) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('onesignal_device_id', deviceState!.userId!);
        debugPrint("💾 Saved Device ID: ${deviceState.userId}");
      }
    });
  }

  Future<void> _playNotificationSound() async {
    try {
      await audioPlayer.stop(); // إيقاف أي صوت سابق
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
        await Vibration.vibrate(
          pattern: [500, 250, 500, 250, 500],
          intensities: [255, 128, 255, 128, 255],
        );
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
      // إذا كان WebView غير جاهز، حفظ URL للتحميل لاحقاً
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
          appBar: AppBar(
            toolbarHeight: 0,
            backgroundColor: const Color(0xFF4F46E5),
            elevation: 0,
          ),
          body: _buildBody(),
        ),
      ),
    );
  }

  Widget _buildBody() {
    return Stack(
      children: [
        // WebView الرئيسي
        _buildWebView(),
        
        // مؤشر التحميل
        if (_isLoading)
          Container(
            color: Colors.white,
            child: const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  CircularProgressIndicator(
                    color: Color(0xFF4F46E5),
                    strokeWidth: 3,
                  ),
                  SizedBox(height: 16),
                  Text(
                    'جاري تحميل تطبيق السائق...',
                    style: TextStyle(
                      color: Color(0xFF4F46E5),
                      fontSize: 16,
                      fontFamily: 'Tajawal',
                    ),
                  ),
                ],
              ),
            ),
          ),
        
        // رسالة عدم الاتصال
        if (_connectivityStatus == ConnectivityResult.none)
          Container(
            color: Colors.black54,
            child: Center(
              child: Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.wifi_off,
                      size: 50,
                      color: Colors.red,
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'لا يوجد اتصال بالإنترنت',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        fontFamily: 'Tajawal',
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'يرجى التحقق من اتصالك وإعادة المحاولة',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 14,
                        fontFamily: 'Tajawal',
                      ),
                    ),
                    const SizedBox(height: 16),
                    ElevatedButton(
                      onPressed: () {
                        if (webViewController != null) {
                          webViewController!.reload();
                        }
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF4F46E5),
                      ),
                      child: const Text(
                        'إعادة المحاولة',
                        style: TextStyle(
                          fontFamily: 'Tajawal',
                          fontWeight: FontWeight.bold,
                        ),
                      ),
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
      initialUrlRequest: URLRequest(
        url: WebUri(_currentUrl.isNotEmpty 
            ? _currentUrl 
            : "https://driver.zoonasd.com/"),
      ),
      initialSettings: InAppWebViewSettings(
        // إعدادات الأداء
        javaScriptEnabled: true,
        javaScriptCanOpenWindowsAutomatically: true,
        supportMultipleWindows: true,
        useHybridComposition: true,
        cacheMode: CacheMode.LOAD_DEFAULT,
        domStorageEnabled: true,
        databaseEnabled: true,
        useShouldOverrideUrlLoading: true,
        
        // إعدادات الواجهة
        transparentBackground: true,
        disableVerticalScroll: false,
        disableHorizontalScroll: false,
        disableContextMenu: false,
        
        // إعدادات المستخدم
        userAgent: 'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/119.0.0.0 Mobile Safari/537.36 TarhalDriver/1.0',
        applicationNameForUserAgent: 'Tarhal Driver App',
        
        // إعدادات الوسائط
        mediaPlaybackRequiresUserGesture: false,
        allowsInlineMediaPlayback: true,
        
        // إعدادات الأمان
        mixedContentMode: MixedContentMode.MIXED_CONTENT_ALWAYS_ALLOW,
        safeBrowsingEnabled: true,
      ),
      pullToRefreshController: pullToRefreshController,
      onWebViewCreated: (controller) {
        webViewController = controller;
        debugPrint("🌐 WebView created successfully");
      },
      onLoadStart: (controller, url) {
        setState(() {
          _isLoading = true;
        });
        debugPrint("🔄 Loading started: $url");
      },
      onLoadStop: (controller, url) async {
        setState(() {
          _isLoading = false;
          _currentUrl = url?.toString() ?? '';
        });
        
        // استخراج driver_id من URL وحفظه في OneSignal
        if (url != null && url.queryParameters.containsKey('driver_id')) {
          final driverId = url.queryParameters['driver_id'];
          if (driverId != null && driverId.isNotEmpty) {
            await OneSignal.shared.setExternalUserId(driverId);
            debugPrint("🔗 Linked to Driver ID: $driverId");
            
            // حفظ في SharedPreferences
            final prefs = await SharedPreferences.getInstance();
            await prefs.setString('driver_id', driverId);
          }
        }
        
        debugPrint("✅ Loading completed: $url");
      },
      onLoadError: (controller, url, code, message) {
        setState(() {
          _isLoading = false;
        });
        debugPrint("❌ Load error: $message (Code: $code)");
      },
      onProgressChanged: (controller, progress) {
        debugPrint("📊 Loading progress: $progress%");
      },
      shouldOverrideUrlLoading: (controller, navigationAction) async {
        final uri = navigationAction.request.url;
        if (uri == null) return NavigationActionPolicy.ALLOW;
        
        // السماح فقط بنطاق driver.zoonasd.com
        if (uri.host == "driver.zoonasd.com") {
          return NavigationActionPolicy.ALLOW;
        }
        
        // فتح الروابط الخارجية في متصفح خارجي
        if (await canLaunchUrl(uri)) {
          await launchUrl(
            uri,
            mode: LaunchMode.externalApplication,
          );
          return NavigationActionPolicy.CANCEL;
        }
        
        return NavigationActionPolicy.ALLOW;
      },
      onCreateWindow: (controller, createWindowAction) async {
        // فتح النوافذ المنبثقة في متصفح خارجي
        final uri = createWindowAction.request.url;
        if (uri != null && await canLaunchUrl(uri)) {
          await launchUrl(
            uri,
            mode: LaunchMode.externalApplication,
          );
        }
        return true;
      },
      onConsoleMessage: (controller, consoleMessage) {
        debugPrint("📝 Console: ${consoleMessage.message}");
      },
    );
  }
}