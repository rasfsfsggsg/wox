import 'dart:io';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';

// ============================================================
// CONFIG
// ============================================================
const String kAppUrl = 'https://nh.igadgets.org/app/app.php';

// Bump this (_v3, _v4, ...) any time you change the notification
// sound file. Android locks a channel's sound permanently once the
// channel is created on a device, so an ID bump (or app
// uninstall/reinstall) is the only way to change it later.
const String kNotifChannelId = 'velowox_channel_v2';
const String kNotifChannelName = 'VeloWox Alerts';

// File must exist at: android/app/src/main/res/raw/notification_sound.mp3
// (lowercase letters/numbers/underscore only — no spaces/dashes, no extension here)
const String kNotifSoundResource = 'notification_sound';

// Server-side ajax endpoints (PHP backend behind app.php) that persist /
// remove the FCM token against the currently logged-in Traccar session.
// See file-reading note below for why we go through app.php instead of
// calling the Traccar REST API directly from Flutter.
const String kAjaxSaveToken = 'ajax=save_fcm_token';
const String kAjaxRemoveToken = 'ajax=remove_fcm_token';

// Any URL whose path contains one of these substrings is treated as a
// logout action. Adjust this list to match your actual PHP app's logout
// link/route if it differs (e.g. 'action=logout', 'signout', etc).
const List<String> kLogoutUrlMarkers = ['logout'];

// ============================================================
// LOCAL NOTIFICATIONS PLUGIN
// ============================================================
final FlutterLocalNotificationsPlugin _localNotifs =
FlutterLocalNotificationsPlugin();

/// Kept globally so the debug panel can display/copy it.
String? globalFcmToken;

void _log(String msg) {
  if (kDebugMode) debugPrint(msg);
}

// ============================================================
// BACKGROUND HANDLER (must be a top-level / static function)
// ============================================================
@pragma('vm:entry-point')
Future<void> _fcmBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
  _log('############################################################');
  _log('🔔 [FCM-BACKGROUND] Notification received (app background/killed)');
  _log('   id=${message.messageId} title=${message.notification?.title}');
  _log('   body=${message.notification?.body} data=${message.data}');
  _log('############################################################');
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  _log('🚀 App start — initializing Firebase...');
  await Firebase.initializeApp();
  _log('✅ Firebase initialized');

  FirebaseMessaging.onBackgroundMessage(_fcmBackgroundHandler);

  await _initLocalNotifications();

  runApp(const VeloWoxApp());
}

// ============================================================
// LOCAL NOTIFICATION CHANNEL SETUP (with custom sound)
// ============================================================
Future<void> _initLocalNotifications() async {
  _log('🔧 Setting up local notification channel...');

  const AndroidInitializationSettings androidInit =
  AndroidInitializationSettings('@mipmap/ic_launcher');
  const InitializationSettings initSettings =
  InitializationSettings(android: androidInit);

  await _localNotifs.initialize(
    initSettings,
    onDidReceiveNotificationResponse: (NotificationResponse response) {
      _log('👆 Notification tapped: payload=${response.payload}');
    },
  );

  const AndroidNotificationChannel androidChannel = AndroidNotificationChannel(
    kNotifChannelId,
    kNotifChannelName,
    description: 'VeloWox vehicle alerts (overspeed, ignition, geofence, etc.)',
    importance: Importance.max,
    playSound: true,
    sound: RawResourceAndroidNotificationSound(kNotifSoundResource),
    enableVibration: true,
  );

  final androidImpl = _localNotifs.resolvePlatformSpecificImplementation<
      AndroidFlutterLocalNotificationsPlugin>();

  await androidImpl?.createNotificationChannel(androidChannel);

  final bool? enabled = await androidImpl?.areNotificationsEnabled();
  _log('✅ Channel "$kNotifChannelId" created with sound "$kNotifSoundResource"');
  _log('🔎 Notifications enabled at OS level? $enabled');
}

// ============================================================
// APP ROOT
// ============================================================
class VeloWoxApp extends StatelessWidget {
  const VeloWoxApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'VeloWox',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: const Color(0xff1565C0)),
      home: const WebViewScreen(),
    );
  }
}

// ============================================================
// WEBVIEW SCREEN
// ============================================================
class WebViewScreen extends StatefulWidget {
  const WebViewScreen({super.key});

  @override
  State<WebViewScreen> createState() => _WebViewScreenState();
}

class _WebViewScreenState extends State<WebViewScreen> {
  late final WebViewController controller;
  bool loading = true;
  String? pendingToken;
  bool showDebugPanel = false;

  @override
  void initState() {
    super.initState();
    _log('🗺️ WebViewScreen init — loading $kAppUrl');

    _requestPermissions();
    _setupWebView();
    _setupFcm();
  }

  // ------------------------------------------------------------
  // PERMISSIONS
  // ------------------------------------------------------------
  Future<void> _requestPermissions() async {
    _log('🔑 Requesting permissions...');
    final statuses = await [
      Permission.location,
      Permission.camera,
      Permission.notification,
      Permission.storage,
    ].request();

    statuses.forEach((perm, status) => _log('🔑 $perm => $status'));

    final notifStatus = await Permission.notification.status;
    if (!notifStatus.isGranted) {
      _log('⚠️ WARNING: notification permission NOT granted — pushes will not show.');
    }
  }

  // ------------------------------------------------------------
  // WEBVIEW SETUP
  // ------------------------------------------------------------
  void _setupWebView() {
    controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.white)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (url) {
            _log('🌐 Page started: $url');
            setState(() => loading = true);
          },
          onPageFinished: (url) async {
            _log('✅ Page finished: $url');
            setState(() => loading = false);
            if (pendingToken != null) {
              final token = pendingToken!;
              pendingToken = null;
              await _pushTokenToServer(token);
            }
          },
          onWebResourceError: (error) {
            _log('❌ WebView error: ${error.description} (code ${error.errorCode})');
          },
          onNavigationRequest: (request) => _handleNavigationRequest(request),
        ),
      )
      ..loadRequest(Uri.parse(kAppUrl));
  }

  // Intercepts navigation. Its only special job: if the user is about to
  // navigate to a logout URL, remove this device's FCM token from the
  // server *first* (while the WebView's session/cookies are still valid),
  // then let the logout navigation continue as normal.
  Future<NavigationDecision> _handleNavigationRequest(
      NavigationRequest request,
      ) async {
    _log('➡️ Navigating to: ${request.url}');

    final bool isLogout = kLogoutUrlMarkers
        .any((marker) => request.url.toLowerCase().contains(marker));

    if (isLogout) {
      _log('🚪 Logout navigation detected — removing FCM token before it fires');
      final String? token = globalFcmToken;
      if (token != null) {
        // Run in the *current* page context so the auth session is still
        // present, and await it so it actually leaves before we navigate.
        await _removeTokenFromServer(token);
        globalFcmToken = null;
        pendingToken = null;
      } else {
        _log('⚠️ No FCM token on file — nothing to remove');
      }
    }

    return NavigationDecision.navigate;
  }

  // ------------------------------------------------------------
  // FCM SETUP
  // ------------------------------------------------------------
  Future<void> _setupFcm() async {
    final messaging = FirebaseMessaging.instance;

    _log('🔔 Requesting FCM notification permission...');
    final settings = await messaging.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );
    _log('🔔 FCM permission status: ${settings.authorizationStatus}');

    if (settings.authorizationStatus == AuthorizationStatus.denied) {
      _log('⛔ FCM permission denied — notifications will not show until enabled in Settings');
    }

    await messaging.setForegroundNotificationPresentationOptions(
      alert: true,
      badge: true,
      sound: true,
    );

    // ---- Initial token ----
    final String? token = await messaging.getToken();
    globalFcmToken = token;
    _log('🔑 FCM TOKEN: $token');

    if (token == null) {
      _log('❌ Token is null — check google-services.json / Firebase setup');
    }

    if (mounted) setState(() {});

    if (token != null) {
      pendingToken = token;
      _pushTokenToServer(token);
    }

    // ---- Token refresh: Firebase can rotate the token at any time, so
    // the *old* token must be swapped out with the server too, not just
    // the new one registered. ----
    messaging.onTokenRefresh.listen((String newToken) async {
      _log('🔄 FCM token refreshed: $newToken');
      final String? oldToken = globalFcmToken;

      globalFcmToken = newToken;
      pendingToken = newToken;
      if (mounted) setState(() {});

      await _pushTokenToServer(newToken);
      if (oldToken != null && oldToken != newToken) {
        await _removeTokenFromServer(oldToken);
      }
    });

    // ---- Foreground message ----
    FirebaseMessaging.onMessage.listen((RemoteMessage message) {
      _log('🔔 [FCM-FOREGROUND] ${message.notification?.title} / ${message.notification?.body}');
      _showLocalNotification(message);

      if (message.data['reload'] == 'true') {
        _log('🔄 Reloading WebView due to notification data flag');
        controller.reload();
      }
    });

    // ---- Notification tapped while app running ----
    FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
      _log('👆 [FCM-TAPPED] data=${message.data}');
      _openFromNotificationData(message.data);
    });

    // ---- App launched cold, directly from a notification tap ----
    final RemoteMessage? initialMessage = await messaging.getInitialMessage();
    if (initialMessage != null) {
      _log('🚀 [FCM-INITIAL] App opened fresh via notification tap: ${initialMessage.data}');
      Future.delayed(const Duration(milliseconds: 800), () {
        _openFromNotificationData(initialMessage.data);
      });
    }
  }

  void _openFromNotificationData(Map<String, dynamic> data) {
    final String? url = data['url'] as String?;
    controller.loadRequest(Uri.parse((url != null && url.isNotEmpty) ? url : kAppUrl));
  }

  // ------------------------------------------------------------
  // LOCAL NOTIFICATION DISPLAY
  // ------------------------------------------------------------
  Future<void> _showLocalNotification(RemoteMessage message) async {
    final notification = message.notification;
    final String title = notification?.title ?? message.data['title'] ?? 'VeloWox Alert';
    final String body = notification?.body ?? message.data['body'] ?? '';
    await _fireLocalNotification(title, body, jsonEncode(message.data));
  }

  /// Independent of FCM — fires a local notification directly so you can
  /// verify permission / channel / custom sound are all working even
  /// without a real push arriving.
  Future<void> _sendTestNotification() async {
    _log('🧪 Test button pressed — firing local test notification');
    await _fireLocalNotification(
      'Test Notification 🔔',
      'If you see this with the custom sound, everything is OK.',
      '{"test":"true"}',
    );
  }

  Future<void> _fireLocalNotification(String title, String body, String payload) async {
    final androidDetails = AndroidNotificationDetails(
      kNotifChannelId,
      kNotifChannelName,
      channelDescription: 'VeloWox vehicle alerts',
      importance: Importance.max,
      priority: Priority.high,
      playSound: true,
      sound: const RawResourceAndroidNotificationSound(kNotifSoundResource),
      enableVibration: true,
      icon: '@mipmap/ic_launcher',
    );

    final notifDetails = NotificationDetails(android: androidDetails);
    final int notifId = DateTime.now().millisecondsSinceEpoch.remainder(100000);

    try {
      await _localNotifs.show(notifId, title, body, notifDetails, payload: payload);
      _log('🔊 Local notification fired: "$title" — "$body"');
    } catch (e, st) {
      _log('❌ Local notification error: $e\n$st');
    }
  }

  // ------------------------------------------------------------
  // SERVER SYNC — token save / remove
  //
  // We go through the PHP app's own ajax endpoints (via a JS fetch()
  // injected into the WebView) instead of calling Traccar's REST API
  // directly from Dart. That way the request rides on the WebView's
  // existing authenticated session/cookies with zero extra auth code in
  // Flutter. app.php is expected to translate these into the underlying
  // Traccar calls:
  //   save   -> POST /api/users/{userId}/tokens   {"type":"firebase","token":...}
  //   remove -> DELETE the matching token row for that user
  // ------------------------------------------------------------
  Future<void> _pushTokenToServer(String token) async {
    await _runTokenAjax(kAjaxSaveToken, token, actionLabel: 'save');
  }

  Future<void> _removeTokenFromServer(String token) async {
    await _runTokenAjax(kAjaxRemoveToken, token, actionLabel: 'remove');
  }

  Future<void> _runTokenAjax(
      String ajaxAction,
      String token, {
        required String actionLabel,
      }) async {
    try {
      final String platform = kIsWeb
          ? 'web'
          : (Platform.isAndroid ? 'android' : 'ios');
      _log('📤 Sending "$actionLabel" for FCM token to server ($platform)...');

      final tokenJson = jsonEncode(token);
      final platformJson = jsonEncode(platform);
      final actionJson = jsonEncode(ajaxAction);

      await controller.runJavaScript('''
        (() => {
          const endpoint = 'app.php?' + $actionJson;
          const payload = {
            token: $tokenJson,
            platform: $platformJson
          };

          fetch(endpoint, {
            method: 'POST',
            credentials: 'include',
            headers: {'Content-Type': 'application/json'},
            body: JSON.stringify(payload)
          })
          .then(async (response) => {
            const text = await response.text();
            let data;
            try { data = JSON.parse(text); }
            catch (_) { data = {success: false, raw: text}; }

            console.log(
              'FCM token $actionLabel result:',
              JSON.stringify(data)
            );
          })
          .catch(error => console.log(
            'FCM token $actionLabel fail:',
            error
          ));
        })();
      ''');

      _log('✅ Token $actionLabel JS executed (check server logs for confirmation)');
    } catch (e, st) {
      _log('❌ FCM token $actionLabel error: $e\n$st');
    }
  }

  void _copyTokenToClipboard() {
    if (globalFcmToken == null) return;
    Clipboard.setData(ClipboardData(text: globalFcmToken!));
    _log('📋 Token copied to clipboard');
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('FCM Token copied to clipboard'), duration: Duration(seconds: 2)),
    );
  }

  // ------------------------------------------------------------
  // UI
  // ------------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvoked: (bool didPop) async {
        if (didPop) return;
        if (await controller.canGoBack()) {
          controller.goBack();
        } else {
          if (context.mounted) Navigator.of(context).maybePop();
        }
      },
      child: Scaffold(
        body: SafeArea(
          child: Stack(
            children: [
              WebViewWidget(controller: controller),
              if (loading) const Center(child: CircularProgressIndicator()),
              _buildDebugPanel(),
            ],
          ),
        ),
      ),
    );
  }

  // Testing-only overlay — safe to delete this widget for production builds.
  Widget _buildDebugPanel() {
    return Positioned(
      right: 10,
      bottom: 10,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (showDebugPanel)
            Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.all(10),
              constraints: const BoxConstraints(maxWidth: 260),
              decoration: BoxDecoration(
                color: Colors.black87,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('FCM Debug',
                      style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12)),
                  const SizedBox(height: 6),
                  Text(
                    globalFcmToken ?? 'Token loading...',
                    style: const TextStyle(color: Colors.greenAccent, fontSize: 9),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextButton(
                        onPressed: _copyTokenToClipboard,
                        child: const Text('Copy Token', style: TextStyle(fontSize: 11)),
                      ),
                      TextButton(
                        onPressed: _sendTestNotification,
                        child: const Text('Test Notif', style: TextStyle(fontSize: 11)),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          FloatingActionButton.small(
            heroTag: 'debug-toggle',
            backgroundColor: Colors.black54,
            onPressed: () => setState(() => showDebugPanel = !showDebugPanel),
            child: const Icon(Icons.bug_report, color: Colors.white, size: 18),
          ),
        ],
      ),
    );
  }
}