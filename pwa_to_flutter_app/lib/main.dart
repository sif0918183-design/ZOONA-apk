import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:onesignal_flutter/onesignal_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:permission_handler/permission_handler.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // تهيئة Supabase
  await Supabase.initialize(
    url: 'https://zsmlyiygjagmhnglrhoa.supabase.co',
    anonKey: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InpzbWx5aXlnamFnbWhuZ2xyaG9hIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NjU5NDc3NjMsImV4cCI6MjA4MTUyMzc2M30.QviVinAng-ILq0umvI5UZCFEvNpP3nI0kW_hSaXxNps',
  );

  // تهيئة OneSignal مع إعدادات متقدمة
  await OneSignal.initialize('c05c5d16-4e72-4d4a-b1a2-6e7e06232d98');
  
  // إعدادات مهمة
  await OneSignal.shared.setLogLevel(OSLogLevel.verbose, OSLogLevel.none);
  await OneSignal.shared.setRequiresUserPrivacyConsent(false);
  
  // طلب إذن الإشعارات
  await OneSignal.shared.promptUserForPushNotificationPermission(
    fallbackToSettings: true,
  );

  // تمكين WebView debugging
  if (Platform.isAndroid) {
    await InAppWebViewController.setWebContentsDebuggingEnabled(kDebugMode);
  }

  // تمكين الأذونات
  await _requestPermissions();

  runApp(const TarhalZoonaDriverApp());
}

Future<void> _requestPermissions() async {
  if (Platform.isAndroid) {
    await Permission.notification.request();
    await Permission.location.request();
    await Permission.locationAlways.request();
  } else if (Platform.isIOS) {
    await Permission.notification.request();
    await Permission.location.request();
    await Permission.locationWhenInUse.request();
  }
}

class TarhalZoonaDriverApp extends StatelessWidget {
  const TarhalZoonaDriverApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'ترحال زونا - السائق',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        fontFamily: 'Tajawal',
        useMaterial3: true,
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF4f46e5),
          foregroundColor: Colors.white,
          elevation: 2,
        ),
        scaffoldBackgroundColor: Colors.white,
      ),
      darkTheme: ThemeData.dark().copyWith(
        primaryColor: const Color(0xFF4f46e5),
        scaffoldBackgroundColor: Colors.grey[900],
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

class _DriverHomeScreenState extends State<DriverHomeScreen> 
    with WidgetsBindingObserver {
  InAppWebViewController? _webViewController;
  bool _isLoading = true;
  bool _isOnline = false;
  String? _currentDriverId;
  String? _currentPushToken;
  late final SupabaseClient _supabase;
  late final StreamSubscription<ConnectivityResult> _connectivitySubscription;
  
  // مؤقتات للتحديث
  Timer? _tokenUpdateTimer;
  Timer? _onlineStatusTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    
    _supabase = Supabase.instance.client;
    
    // مراقبة الاتصال بالإنترنت
    _setupConnectivityMonitoring();
    
    // إعداد OneSignal
    _setupOneSignal();
    
    // بدء التحديث الدوري
    _startPeriodicUpdates();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _connectivitySubscription.cancel();
    _tokenUpdateTimer?.cancel();
    _onlineStatusTimer?.cancel();
    super.dispose();
  }

  void _setupConnectivityMonitoring() {
    _connectivitySubscription = Connectivity()
        .onConnectivityChanged
        .listen(_updateConnectionStatus);
  }

  Future<void> _updateConnectionStatus(ConnectivityResult result) async {
    final isConnected = result != ConnectivityResult.none;
    
    setState(() {
      _isOnline = isConnected;
    });
    
    if (isConnected && _currentDriverId != null) {
      await _updateDriverOnlineStatus(true);
    }
  }

  void _setupOneSignal() {
    // معالج الإشعارات في الخلفية
    OneSignal.shared.setNotificationWillShowInForegroundHandler(
      (OSNotificationReceivedEvent event) {
        debugPrint('🔔 إشعار في الخلفية: ${event.notification.body}');
        
        final additionalData = event.notification.additionalData;
        if (additionalData != null && additionalData['type'] == 'ride_request') {
          // معالجة طلب الرحلة
          _handleRideRequestNotification(event.notification, additionalData);
        }
        
        event.complete(event.notification);
      },
    );

    // معالج فتح الإشعار
    OneSignal.shared.setNotificationOpenedHandler((OSNotificationOpenedResult result) {
      debugPrint('🎯 إشعار تم فتحه: ${result.notification.body}');
      
      final additionalData = result.notification.additionalData;
      if (additionalData != null && additionalData['type'] == 'ride_request') {
        _openRideDetails(additionalData);
      }
    });

    // مراقبة التغييرات في التوكن
    OneSignal.shared.addSubscriptionObserver((changes) async {
      if (changes.to.userId != null && _currentDriverId != null) {
        await _updatePushTokenInDatabase(changes.to.userId!);
      }
    });
  }

  Future<void> _handleRideRequestNotification(
      OSNotification notification, 
      Map<String, dynamic> additionalData) async {
    
    // عرض إشعار محلي
    await _showLocalNotification(notification, additionalData);
    
    // إرسال الإشعار إلى WebView
    if (_webViewController != null) {
      await _webViewController!.evaluateJavascript(source: """
        if (window.handleRideRequest) {
          window.handleRideRequest(${jsonEncode(additionalData)});
        } else {
          console.log('🔔 إشعار رحلة جديدة:', ${jsonEncode(additionalData)});
          
          // إنشاء إشعار في الواجهة
          const notification = document.createElement('div');
          notification.style.cssText = \`
            position: fixed;
            top: 20px;
            right: 20px;
            width: 320px;
            background: linear-gradient(135deg, #4f46e5, #4338ca);
            color: white;
            padding: 15px;
            border-radius: 12px;
            z-index: 999999;
            box-shadow: 0 8px 25px rgba(79, 70, 229, 0.3);
            border: 1px solid rgba(255, 255, 255, 0.1);
            backdrop-filter: blur(10px);
          \`;
          
          notification.innerHTML = \`
            <div style="display: flex; align-items: center; gap: 12px; margin-bottom: 10px;">
              <div style="font-size: 24px;">🎯</div>
              <div>
                <h4 style="margin: 0; font-size: 16px; font-weight: 800;">طلب رحلة جديد</h4>
                <p style="margin: 5px 0 0 0; font-size: 12px; opacity: 0.9;">
                  \${new Date().toLocaleTimeString('ar-SA')}
                </p>
              </div>
            </div>
            <p style="margin: 8px 0; font-size: 14px;">
              <strong>\${additionalData.customer_name}</strong>
            </p>
            <p style="margin: 8px 0; font-size: 13px;">
              \${additionalData.pickup_address}
            </p>
            <div style="display: flex; justify-content: space-between; margin-top: 15px;">
              <button onclick="acceptRide('\${additionalData.ride_id}')" 
                style="background: #10b981; color: white; border: none; padding: 8px 16px; border-radius: 8px; cursor: pointer; font-weight: 600;">
                قبول
              </button>
              <button onclick="rejectRide('\${additionalData.ride_id}')" 
                style="background: #ef4444; color: white; border: none; padding: 8px 16px; border-radius: 8px; cursor: pointer; font-weight: 600;">
                رفض
              </button>
            </div>
          \`;
          
          document.body.appendChild(notification);
          
          setTimeout(() => notification.remove(), 30000);
        }
      """);
    }
  }

  Future<void> _showLocalNotification(
      OSNotification notification, 
      Map<String, dynamic> additionalData) async {
    
    // يمكنك استخدام flutter_local_notifications هنا
    // هذا مجرد مثال
    debugPrint('📱 عرض إشعار محلي: ${notification.body}');
  }

  void _openRideDetails(Map<String, dynamic> rideData) {
    final rideId = rideData['ride_id'];
    final requestId = rideData['request_id'];
    
    if (_webViewController != null) {
      _webViewController!.evaluateJavascript(source: """
        window.location.href = '/ride-details.html?rideId=$rideId&requestId=$requestId';
      """);
    }
  }

  void _startPeriodicUpdates() {
    // تحديث التوكن كل 10 دقائق
    _tokenUpdateTimer = Timer.periodic(const Duration(minutes: 10), (timer) async {
      await _updatePushTokenIfNeeded();
    });

    // تحديث حالة الاتصال كل دقيقة
    _onlineStatusTimer = Timer.periodic(const Duration(minutes: 1), (timer) async {
      if (_currentDriverId != null) {
        await _updateDriverOnlineStatus(_isOnline);
      }
    });
  }

  Future<void> _updatePushTokenIfNeeded() async {
    try {
      final deviceState = await OneSignal.shared.getDeviceState();
      final currentToken = deviceState?.userId;
      
      if (currentToken != null && currentToken != _currentPushToken) {
        await _updatePushTokenInDatabase(currentToken);
      }
    } catch (e) {
      debugPrint('❌ خطأ في تحديث التوكن: $e');
    }
  }

  Future<void> _updatePushTokenInDatabase(String pushToken) async {
    if (_currentDriverId == null) return;

    try {
      debugPrint('🔄 تحديث توكن السائق في قاعدة البيانات');
      
      final response = await _supabase
          .from('drivers')
          .update({
            'push_token': pushToken,
            'push_token_updated_at': DateTime.now().toIso8601String(),
          })
          .eq('id', _currentDriverId);

      debugPrint('✅ تم تحديث توكن السائق');
      
      _currentPushToken = pushToken;
      
    } catch (e) {
      debugPrint('❌ خطأ في تحديث قاعدة البيانات: $e');
    }
  }

  Future<void> _updateDriverOnlineStatus(bool isOnline) async {
    if (_currentDriverId == null) return;

    try {
      await _supabase
          .from('driver_locations')
          .update({
            'is_online': isOnline,
            'updated_at': DateTime.now().toIso8601String(),
          })
          .eq('driver_id', _currentDriverId);

      if (isOnline) {
        debugPrint('✅ حالة السائق: متصل');
      } else {
        debugPrint('⚠️  حالة السائق: غير متصل');
      }
    } catch (e) {
      debugPrint('❌ خطأ في تحديث حالة الاتصال: $e');
    }
  }

  Future<void> _syncDriverWithDatabase(InAppWebViewController controller) async {
    try {
      debugPrint('🔄 جاري مزامنة بيانات السائق...');

      // قراءة driver_id من localStorage
      final driverId = await controller.evaluateJavascript(source: """
        localStorage.getItem('driver_id') || 
        localStorage.getItem('tarhal_driver_id') || 
        localStorage.getItem('driverId') ||
        sessionStorage.getItem('driver_id');
      """);

      if (driverId == null || driverId.toString().trim() == 'null') {
        debugPrint('⏳ driver_id غير موجود، جاري الانتظار...');
        
        // المحاولة مرة أخرى بعد 2 ثانية
        await Future.delayed(const Duration(seconds: 2));
        
        final retryId = await controller.evaluateJavascript(source: """
          localStorage.getItem('driver_id') || 
          localStorage.getItem('tarhal_driver_id');
        """);
        
        if (retryId == null || retryId.toString().trim() == 'null') {
          debugPrint('❌ لم يتم العثور على driver_id');
          return;
        }
        
        _currentDriverId = retryId.toString();
      } else {
        _currentDriverId = driverId.toString();
      }

      // تنظيف الـ driver_id
      _currentDriverId = _currentDriverId!.replaceAll('"', '').trim();
      
      if (_currentDriverId!.length < 10) {
        debugPrint('❌ driver_id قصير جداً: $_currentDriverId');
        return;
      }

      debugPrint('✅ driver_id: ${_currentDriverId!.substring(0, 20)}...');

      // الحصول على push token
      final deviceState = await OneSignal.shared.getDeviceState();
      final pushToken = deviceState?.userId;

      if (pushToken == null) {
        debugPrint('❌ لم يتم الحصول على push token');
        
        // المحاولة مرة أخرى
        await Future.delayed(const Duration(seconds: 3));
        final retryDeviceState = await OneSignal.shared.getDeviceState();
        final retryToken = retryDeviceState?.userId;
        
        if (retryToken == null) {
          debugPrint('❌ فشل الحصول على push token');
          return;
        }
        
        await _updatePushTokenInDatabase(retryToken);
      } else {
        await _updatePushTokenInDatabase(pushToken);
      }

      // تحديث حالة السائق على أنه متصل
      await _updateDriverOnlineStatus(true);

      // حفظ التوكن في localStorage للـ PWA
      await controller.evaluateJavascript(source: """
        localStorage.setItem('driver_push_token', '$pushToken');
        localStorage.setItem('driver_push_token_synced', 'true');
        
        if (typeof window.onDriverTokenUpdate === 'function') {
          window.onDriverTokenUpdate('$pushToken');
        }
        
        console.log('✅ تم مزامنة التوكن مع Flutter');
      """);

      // تحميل معالج الإشعارات في الـ WebView
      await _loadNotificationHandlers(controller);

      debugPrint('🚀 تم مزامنة السائق بنجاح');

    } catch (e) {
      debugPrint('❌ خطأ في مزامنة السائق: $e');
      
      // إعادة المحاولة في حالة الفشل
      await Future.delayed(const Duration(seconds: 5));
      if (controller != null && mounted) {
        await _syncDriverWithDatabase(controller);
      }
    }
  }

  Future<void> _loadNotificationHandlers(InAppWebViewController controller) async {
    await controller.evaluateJavascript(source: """
      // دالة لمعالجة طلبات الرحلات
      window.handleRideRequest = function(data) {
        console.log('🔔 استلام طلب رحلة:', data);
        
        // عرض إشعار في الواجهة
        showRideNotification(data);
      };
      
      function showRideNotification(data) {
        // كود عرض الإشعار هنا
        console.log('عرض إشعار رحلة:', data);
      }
      
      // تعريض دوال القبول والرفض
      window.acceptRide = function(rideId) {
        window.location.href = '/accept-ride.html?id=' + rideId;
      };
      
      window.rejectRide = function(rideId) {
        if (confirm('هل تريد رفض هذه الرحلة؟')) {
          fetch('/api/reject-ride', {
            method: 'POST',
            headers: {'Content-Type': 'application/json'},
            body: JSON.stringify({ rideId: rideId })
          });
        }
      };
      
      console.log('✅ تم تحميل معالجات الإشعارات');
    """);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Stack(
          children: [
            // WebView الرئيسي
            InAppWebView(
              initialUrlRequest: URLRequest(
                url: WebUri("https://driver.zoonasd.com/"),
                headers: {
                  'User-Agent': 'TarhalZoonaDriver/1.0.0',
                },
              ),
              onWebViewCreated: (controller) {
                _webViewController = controller;
              },
              onLoadStart: (controller, url) {
                setState(() {
                  _isLoading = true;
                });
              },
              onLoadStop: (controller, url) async {
                setState(() {
                  _isLoading = false;
                });
                
                // مزامنة السائق مع قاعدة البيانات
                await _syncDriverWithDatabase(controller);
              },
              onLoadError: (controller, url, code, message) {
                setState(() {
                  _isLoading = false;
                });
                debugPrint('❌ خطأ في تحميل الصفحة: $message');
              },
              initialSettings: InAppWebViewSettings(
                javaScriptEnabled: true,
                cacheEnabled: true,
                domStorageEnabled: true,
                databaseEnabled: true,
                mediaPlaybackRequiresUserGesture: false,
                allowsInlineMediaPlayback: true,
                transparentBackground: true,
                supportZoom: false,
                useShouldOverrideUrlLoading: true,
              ),
              shouldOverrideUrlLoading: (controller, navigationAction) async {
                final uri = navigationAction.request.url!;
                
                // فتح الروابط الخارجية في المتصفح
                if (!uri.toString().contains('driver.zoonasd.com') &&
                    (uri.toString().startsWith('http://') || 
                     uri.toString().startsWith('https://') ||
                     uri.toString().startsWith('mailto:') ||
                     uri.toString().startsWith('tel:'))) {
                  
                  if (await canLaunchUrl(uri)) {
                    await launchUrl(uri);
                    return NavigationActionPolicy.CANCEL;
                  }
                }
                
                return NavigationActionPolicy.ALLOW;
              },
            ),
            
            // شاشة التحميل
            if (_isLoading)
              Container(
                color: Colors.white,
                child: Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      SizedBox(
                        width: 60,
                        height: 60,
                        child: CircularProgressIndicator(
                          strokeWidth: 3,
                          valueColor: AlwaysStoppedAnimation<Color>(
                            const Color(0xFF4f46e5),
                          ),
                        ),
                      ),
                      const SizedBox(height: 20),
                      const Text(
                        'جاري تحميل تطبيق السائق...',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF4f46e5),
                          fontFamily: 'Tajawal',
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        _isOnline ? 'متصل بالإنترنت' : 'جارٍ الاتصال...',
                        style: TextStyle(
                          fontSize: 14,
                          color: _isOnline ? Colors.green : Colors.orange,
                          fontFamily: 'Tajawal',
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            
            // مؤشر حالة الاتصال
            if (!_isLoading)
              Positioned(
                top: 10,
                left: 10,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: _isOnline ? Colors.green.withOpacity(0.1) : Colors.orange.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: _isOnline ? Colors.green : Colors.orange,
                      width: 1,
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        _isOnline ? Icons.wifi : Icons.wifi_off,
                        size: 14,
                        color: _isOnline ? Colors.green : Colors.orange,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        _isOnline ? 'متصل' : 'غير متصل',
                        style: TextStyle(
                          fontSize: 12,
                          color: _isOnline ? Colors.green : Colors.orange,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
      
      // زر تحديث التوكن (للتطوير فقط)
      floatingActionButton: kDebugMode ? FloatingActionButton(
        onPressed: () async {
          if (_webViewController != null) {
            await _syncDriverWithDatabase(_webViewController!);
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('تم تحديث التوكن'),
                backgroundColor: Colors.green,
              ),
            );
          }
        },
        backgroundColor: const Color(0xFF4f46e5),
        child: const Icon(Icons.refresh, color: Colors.white),
      ) : null,
    );
  }
}