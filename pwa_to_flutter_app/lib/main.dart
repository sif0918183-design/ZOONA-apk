import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:onesignal_flutter/onesignal_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Supabase.initialize(
    url: 'https://zsmlyiygjagmhnglrhoa.supabase.co',
    anonKey: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InpzbWx5aXlnamFnbWhuZ2xyaG9hIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NjU5NDc3NjMsImV4cCI6MjA4MTUyMzc2M30.QviVinAng-ILq0umvI5UZCFEvNpP3nI0kW_hSaXxNps',
  );

  // تهيئة OneSignal مع إعدادات متقدمة
  await OneSignal.shared.setAppId("c05c5d16-4e72-4d4a-b1a2-6e7e06232d98");
  
  // إعدادات مهمة لتحسين تجربة الإشعارات
  await OneSignal.shared.setLogLevel(OSLogLevel.verbose, OSLogLevel.none);
  await OneSignal.shared.setRequiresUserPrivacyConsent(false);
  
  // تمكين الاشعارات في الخلفية
  await OneSignal.shared.promptUserForPushNotificationPermission(
    fallbackToSettings: true,
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

class _MyAppState extends State<MyApp> with WidgetsBindingObserver {
  InAppWebViewController? _webViewController;
  bool _isLoading = true;
  bool _isDriverLoggedIn = false;
  String? _currentDriverId;
  String? _currentPushToken;
  late final SupabaseClient _supabase;
  
  // متغيرات للمعالجة العميقة
  final _notificationStreamController = StreamController<OSNotification>.broadcast();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _supabase = Supabase.instance.client;
    
    // إعداد OneSignal بشكل متقدم
    _setupOneSignal();
    
    // إضافة مستمع لتغيير حالة الجهاز
    OneSignal.shared.addSubscriptionObserver((changes) async {
      if (changes.to.userId != null && _currentDriverId != null) {
        await _updatePushTokenInDatabase(changes.to.userId!);
      }
    });
    
    // إضافة مستمع لتحديثات حالة الجهاز
    OneSignal.shared.addPermissionObserver((changes) {
      debugPrint("OneSignal Permission Changed: ${changes.to}");
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _notificationStreamController.close();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    
    // عند عودة التطبيق إلى الواجهة الأمامية، تحديث التوكن
    if (state == AppLifecycleState.resumed && _currentDriverId != null) {
      _updatePushTokenIfNeeded();
    }
  }

  Future<void> _setupOneSignal() async {
    // إعداد معالج الإشعارات
    OneSignal.shared.setNotificationWillShowInForegroundHandler(
      (OSNotificationReceivedEvent event) {
        debugPrint('🔔 إشعار في الواجهة الأمامية: ${event.notification.body}');
        
        // معالجة الإشعارات بناءً على نوعها
        final notification = event.notification;
        final additionalData = notification.additionalData;
        
        if (additionalData != null && additionalData['type'] == 'ride_request') {
          // عرض الإشعار بشكل مخصص
          event.complete(notification);
          
          // إرسال الإشعار للويب فيو
          _sendNotificationToWebView(notification, additionalData);
        } else {
          event.complete(notification);
        }
      },
    );

    // معالج فتح الإشعار
    OneSignal.shared.setNotificationOpenedHandler((OSNotificationOpenedResult result) {
      debugPrint('🎯 إشعار تم فتحه: ${result.notification.body}');
      
      final additionalData = result.notification.additionalData;
      
      if (additionalData != null && additionalData['type'] == 'ride_request') {
        // فتح الرحلة في الـ WebView
        _openRideInWebView(additionalData);
      }
    });
  }

  Future<void> _openRideInWebView(Map<String, dynamic> rideData) async {
    if (_webViewController != null) {
      final rideId = rideData['ride_id'];
      final requestId = rideData['request_id'];
      
      // الانتقال إلى صفحة تفاصيل الرحلة
      final jsCode = """
        window.location.href = '/ride-details.html?rideId=$rideId&requestId=$requestId';
      """;
      
      await _webViewController?.evaluateJavascript(source: jsCode);
    }
  }

  Future<void> _sendNotificationToWebView(OSNotification notification, Map<String, dynamic> additionalData) async {
    if (_webViewController != null) {
      final jsCode = """
        if (window.handlePushNotification) {
          window.handlePushNotification(${notification.toJson()});
        } else {
          console.warn('handlePushNotification function not found');
        }
      """;
      
      await _webViewController?.evaluateJavascript(source: jsCode);
    }
  }

  Future<void> _updatePushTokenInDatabase(String pushToken) async {
    if (_currentDriverId == null) return;
    
    try {
      debugPrint("🔄 تحديث توكن السائق في قاعدة البيانات");
      debugPrint("   Driver ID: $_currentDriverId");
      debugPrint("   Push Token: ${pushToken.substring(0, 20)}...");
      
      final response = await _supabase
          .from('drivers')
          .update({
            'push_token': pushToken,
            'push_token_updated_at': DateTime.now().toIso8601String(),
            'is_online': true,
            'last_seen': DateTime.now().toIso8601String(),
          })
          .eq('id', _currentDriverId);
      
      debugPrint("✅ تم تحديث توكن السائق في قاعدة البيانات");
      
      // حفظ التوكن محلياً للمقارنة لاحقاً
      _currentPushToken = pushToken;
      
    } catch (e) {
      debugPrint("❌ خطأ في تحديث قاعدة البيانات: $e");
    }
  }

  Future<void> _updatePushTokenIfNeeded() async {
    try {
      final deviceState = await OneSignal.shared.getDeviceState();
      final currentToken = deviceState?.userId;
      
      if (currentToken != null && currentToken != _currentPushToken) {
        await _updatePushTokenInDatabase(currentToken);
      }
    } catch (e) {
      debugPrint("❌ خطأ في التحقق من تحديث التوكن: $e");
    }
  }

  Future<void> _syncDriverWithPushToken(InAppWebViewController controller) async {
    try {
      debugPrint("🔄 جاري مزامنة بيانات السائق...");
      
      // الحصول على driver_id من localStorage في الـ PWA
      final driverId = await controller.evaluateJavascript(source: """
        localStorage.getItem('driver_id') || 
        localStorage.getItem('tarhal_driver_id') || 
        localStorage.getItem('driverId');
      """);
      
      if (driverId == null || driverId.toString().trim() == 'null') {
        debugPrint("⏳ driver_id غير موجود في localStorage، جاري الانتظار...");
        
        // المحاولة مرة أخرى بعد 3 ثواني
        await Future.delayed(const Duration(seconds: 3));
        
        final retryDriverId = await controller.evaluateJavascript(source: """
          localStorage.getItem('driver_id') || 
          localStorage.getItem('tarhal_driver_id') || 
          localStorage.getItem('driverId');
        """);
        
        if (retryDriverId == null || retryDriverId.toString().trim() == 'null') {
          debugPrint("❌ لم يتم العثور على driver_id حتى بعد الانتظار");
          return;
        }
        
        _currentDriverId = retryDriverId.toString();
      } else {
        _currentDriverId = driverId.toString();
      }
      
      // تنظيف driver_id
      _currentDriverId = _currentDriverId!.replaceAll('"', '').trim();
      
      if (_currentDriverId!.length < 10) {
        debugPrint("❌ driver_id قصير جداً: $_currentDriverId");
        return;
      }
      
      debugPrint("✅ driver_id موجود: ${_currentDriverId!.substring(0, 20)}...");
      
      // الحصول على push token من OneSignal
      final deviceState = await OneSignal.shared.getDeviceState();
      final pushToken = deviceState?.userId;
      
      if (pushToken == null) {
        debugPrint("❌ لم يتم الحصول على push token");
        
        // المحاولة مرة أخرى
        await Future.delayed(const Duration(seconds: 2));
        
        final retryDeviceState = await OneSignal.shared.getDeviceState();
        final retryPushToken = retryDeviceState?.userId;
        
        if (retryPushToken == null) {
          debugPrint("❌ فشل الحصول على push token حتى بعد المحاولة");
          return;
        }
        
        await _updatePushTokenInDatabase(retryPushToken);
      } else {
        await _updatePushTokenInDatabase(pushToken);
      }
      
      // تحديث حالة السائق على أنه متصل
      try {
        await _supabase
            .from('driver_locations')
            .update({
              'is_online': true,
              'updated_at': DateTime.now().toIso8601String(),
            })
            .eq('driver_id', _currentDriverId);
        
        debugPrint("✅ تم تحديث حالة السائق على أنه متصل");
      } catch (e) {
        debugPrint("⚠️ خطأ في تحديث حالة السائق: $e");
      }
      
      // تحديث الـ PWA بـ push_token
      final updateJSCode = """
        try {
          localStorage.setItem('driver_push_token', '$pushToken');
          localStorage.setItem('driver_push_token_synced', 'true');
          
          if (window.driverPushTokenUpdated) {
            window.driverPushTokenUpdated('$pushToken');
          }
          
          console.log('✅ Push token synced with Flutter');
        } catch (e) {
          console.error('❌ Error syncing push token:', e);
        }
      """;
      
      await controller.evaluateJavascript(source: updateJSCode);
      
      // إضافة دالة JavaScript للتعامل مع الإشعارات
      final notificationHandlerCode = """
        window.handlePushNotification = function(notification) {
          console.log('🔔 Received push notification in WebView:', notification);
          
          const data = notification.additionalData;
          if (data && data.type === 'ride_request') {
            // عرض إشعار مخصص
            showRideRequestNotification(data);
          }
        };
        
        function showRideRequestNotification(data) {
          const notificationDiv = document.createElement('div');
          notificationDiv.className = 'push-notification';
          notificationDiv.innerHTML = \`
            <div style="position: fixed; top: 20px; right: 20px; width: 300px; background: #4f46e5; color: white; padding: 15px; border-radius: 10px; z-index: 999999; box-shadow: 0 4px 12px rgba(0,0,0,0.15);">
              <h4 style="margin: 0 0 10px 0; font-size: 16px;">
                🎯 طلب رحلة جديد
              </h4>
              <p style="margin: 0 0 8px 0; font-size: 14px;">
                العميل: \${data.customer_name}
              </p>
              <p style="margin: 0 0 8px 0; font-size: 14px;">
                المبلغ: \${data.amount} جنيه
              </p>
              <p style="margin: 0 0 8px 0; font-size: 12px; opacity: 0.9;">
                \${data.distance} - \${data.pickup_address.substring(0, 30)}...
              </p>
              <div style="display: flex; gap: 10px; margin-top: 10px;">
                <button onclick="acceptRideRequest('\${data.ride_id}', '\${data.request_id}')" style="flex: 1; background: #10b981; color: white; border: none; padding: 8px; border-radius: 5px; cursor: pointer;">
                  قبول
                </button>
                <button onclick="rejectRideRequest('\${data.ride_id}', '\${data.request_id}')" style="flex: 1; background: #ef4444; color: white; border: none; padding: 8px; border-radius: 5px; cursor: pointer;">
                  رفض
                </button>
              </div>
            </div>
          \`;
          
          document.body.appendChild(notificationDiv);
          
          // إزالة الإشعار بعد 30 ثانية
          setTimeout(() => {
            if (notificationDiv.parentNode) {
              notificationDiv.remove();
            }
          }, 30000);
        }
        
        // تعريض الدوال للويب فيو
        window.acceptRideRequest = function(rideId, requestId) {
          window.location.href = '/ride-accept.html?rideId=' + rideId + '&requestId=' + requestId;
        };
        
        window.rejectRideRequest = function(rideId, requestId) {
          if (confirm('هل تريد رفض هذه الرحلة؟')) {
            fetch('/api/reject-ride', {
              method: 'POST',
              headers: {'Content-Type': 'application/json'},
              body: JSON.stringify({ rideId: rideId, requestId: requestId })
            });
          }
        };
        
        console.log('✅ Push notification handlers loaded');
      """;
      
      await controller.evaluateJavascript(source: notificationHandlerCode);
      
      debugPrint("🚀 تم مزامنة السائق وتحميل معالج الإشعارات بنجاح");
      
    } catch (e) {
      debugPrint("❌ خطأ في مزامنة السائق: $e");
      
      // إعادة المحاولة في حالة الفشل
      await Future.delayed(const Duration(seconds: 5));
      if (controller != null && mounted) {
        await _syncDriverWithPushToken(controller);
      }
    }
  }

  Future<void> _checkAndUpdateTokenPeriodically() async {
    while (mounted && _currentDriverId != null) {
      await Future.delayed(const Duration(minutes: 5)); // تحديث كل 5 دقائق
      await _updatePushTokenIfNeeded();
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        primarySwatch: Colors.blue,
        useMaterial3: true,
      ),
      home: Scaffold(
        backgroundColor: Colors.white,
        body: SafeArea(
          child: Stack(
            children: [
              // WebView الرئيسي
              InAppWebView(
                initialUrlRequest: URLRequest(
                  url: WebUri("https://driver.zoonasd.com/"),
                  headers: {
                    'User-Agent': 'TarhalZoona-Driver-App/1.0.0',
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
                  
                  // تحميل دالة معالجة الإشعارات
                  await _syncDriverWithPushToken(controller);
                  
                  // بدء التحديث الدوري للتوكن
                  _checkAndUpdateTokenPeriodically();
                  
                  // إضافة مستمع لـ localStorage
                  final localStorageListener = """
                    window.addEventListener('storage', function(e) {
                      if (e.key === 'driver_id' || e.key === 'tarhal_driver_id') {
                        if (window.flutterUpdateDriverId) {
                          window.flutterUpdateDriverId(e.newValue);
                        }
                      }
                    });
                    
                    // تعريض دالة لتحديث driver_id من Flutter
                    window.flutterUpdateDriverId = function(driverId) {
                      console.log('🔄 Driver ID updated from Flutter:', driverId);
                      window.driver_id = driverId;
                      
                      if (window.onDriverIdUpdate) {
                        window.onDriverIdUpdate(driverId);
                      }
                    };
                    
                    console.log('✅ LocalStorage listener loaded');
                  """;
                  
                  await controller.evaluateJavascript(source: localStorageListener);
                },
                onLoadError: (controller, url, code, message) {
                  setState(() {
                    _isLoading = false;
                  });
                  debugPrint("❌ خطأ في تحميل الصفحة: $message");
                },
                onConsoleMessage: (controller, consoleMessage) {
                  debugPrint("🌐 WebView Console: ${consoleMessage.message}");
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
                  disableVerticalScroll: false,
                  disableHorizontalScroll: false,
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
                onTitleChanged: (controller, title) {
                  debugPrint("📝 Title Changed: $title");
                  if (title?.contains('سائق') == true) {
                    setState(() {
                      _isDriverLoggedIn = true;
                    });
                  }
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
                          width: 80,
                          height: 80,
                          child: CircularProgressIndicator(
                            strokeWidth: 3,
                            valueColor: AlwaysStoppedAnimation<Color>(
                              const Color(0xFF4f46e5),
                            ),
                          ),
                        ),
                        const SizedBox(height: 20),
                        const Text(
                          'جاري تحميل ترحال زونا...',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF4f46e5),
                          ),
                        ),
                        const SizedBox(height: 10),
                        const Text(
                          'ربط تطبيق السائق...',
                          style: TextStyle(
                            fontSize: 14,
                            color: Colors.grey,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              
              // زر تحديث التوكن (للأغراض التنفيذية)
              if (!_isLoading && kDebugMode)
                Positioned(
                  top: 10,
                  right: 10,
                  child: FloatingActionButton.small(
                    onPressed: () async {
                      if (_webViewController != null) {
                        await _syncDriverWithPushToken(_webViewController!);
                      }
                    },
                    backgroundColor: const Color(0xFF4f46e5),
                    child: const Icon(Icons.refresh, color: Colors.white),
                  ),
                ),
            ],
          ),
        ),
        // شريط الأدوات السفلي
        bottomNavigationBar: _isDriverLoggedIn
            ? Container(
                height: 60,
                decoration: BoxDecoration(
                  color: Colors.white,
                  border: Border(top: BorderSide(color: Colors.grey[300]!)),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.home, color: Color(0xFF4f46e5)),
                      onPressed: () {
                        _webViewController?.loadUrl(
                          urlRequest: URLRequest(
                            url: WebUri("https://driver.zoonasd.com/"),
                          ),
                        );
                      },
                    ),
                    IconButton(
                      icon: const Icon(Icons.directions_car, color: Color(0xFF4f46e5)),
                      onPressed: () {
                        _webViewController?.evaluateJavascript(source: """
                          window.location.href = '/active-rides.html';
                        """);
                      },
                    ),
                    IconButton(
                      icon: const Icon(Icons.history, color: Color(0xFF4f46e5)),
                      onPressed: () {
                        _webViewController?.evaluateJavascript(source: """
                          window.location.href = '/ride-history.html';
                        """);
                      },
                    ),
                    IconButton(
                      icon: const Icon(Icons.person, color: Color(0xFF4f46e5)),
                      onPressed: () {
                        _webViewController?.evaluateJavascript(source: """
                          window.location.href = '/profile.html';
                        """);
                      },
                    ),
                  ],
                ),
              )
            : null,
      ),
    );
  }
}