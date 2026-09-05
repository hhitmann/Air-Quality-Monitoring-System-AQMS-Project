import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:async';
import 'dart:io';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:overlay_support/overlay_support.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:csv/csv.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:syncfusion_flutter_gauges/gauges.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'background_service.dart';
import 'dart:math';

// -------------------- GLOBAL NOTIFICATION PLUGIN --------------------
final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
    FlutterLocalNotificationsPlugin();

// -------------------- FCM BACKGROUND HANDLER --------------------
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  debugPrint("💬 Background message: ${message.messageId}");
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();

  // ---------- Local notifications init ----------
  const AndroidInitializationSettings androidSettings =
      AndroidInitializationSettings('@mipmap/ic_launcher');
  const DarwinInitializationSettings iosSettings =
      DarwinInitializationSettings();
  const InitializationSettings initSettings = InitializationSettings(
    android: androidSettings,
    iOS: iosSettings,
  );

  const AndroidNotificationChannel channel = AndroidNotificationChannel(
    'aqms_channel',
    'AQMS Alerts',
    importance: Importance.high,
  );
  await flutterLocalNotificationsPlugin
      .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(channel);

  await flutterLocalNotificationsPlugin.initialize(
    initSettings,
    onDidReceiveNotificationResponse: (NotificationResponse response) async {
      if (response.actionId == 'stop_service' || response.payload == 'stop') {
        final service = FlutterBackgroundService();
        service.invoke('stopService');
      }
    },
  );

  await flutterLocalNotificationsPlugin
      .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>()
      ?.requestNotificationsPermission();

  // ---------- FCM init ----------
  FirebaseMessaging messaging = FirebaseMessaging.instance;
  await messaging.requestPermission(
    alert: true,
    announcement: false,
    badge: true,
    sound: true,
    criticalAlert: false,
    provisional: false,
  );

  String? token = await messaging.getToken();
  if (token != null) {
    FirebaseDatabase.instance.ref('device_tokens/$token').set(true);
  }
  messaging.onTokenRefresh.listen((newToken) {
    FirebaseDatabase.instance.ref('device_tokens/$newToken').set(true);
  });
  FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);

  // ---------- BACKGROUND SERVICE CONFIGURATION ----------
  final service = FlutterBackgroundService();
  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onServiceStart,
      autoStart: true,
      isForegroundMode: true,
      notificationChannelId: 'aqms_channel',
      initialNotificationTitle: 'AQMS Monitoring',
      initialNotificationContent: 'Watching for alerts...',
      foregroundServiceTypes: [
        AndroidForegroundType.dataSync,
      ],
    ),
    iosConfiguration: IosConfiguration(
      autoStart: false,
    ),
  );

  runApp(const OverlaySupport.global(child: AQMSProRoot()));
}

// ============================================================
//         EPA AQI CALCULATOR (Outdoor)
// ============================================================
class AqiCalculator {
  static const List<_AqiBreakpoint> _pm25Breakpoints = [
    _AqiBreakpoint(0.0, 9.0, 0, 50),
    _AqiBreakpoint(9.1, 35.4, 51, 100),
    _AqiBreakpoint(35.5, 55.4, 101, 150),
    _AqiBreakpoint(55.5, 125.4, 151, 200),
    _AqiBreakpoint(125.5, 225.4, 201, 300),
    _AqiBreakpoint(225.5, 325.4, 301, 500),
  ];

  static const List<_AqiBreakpoint> _pm10Breakpoints = [
    _AqiBreakpoint(0, 54, 0, 50),
    _AqiBreakpoint(55, 154, 51, 100),
    _AqiBreakpoint(155, 254, 101, 150),
    _AqiBreakpoint(255, 354, 151, 200),
    _AqiBreakpoint(355, 424, 201, 300),
    _AqiBreakpoint(425, 604, 301, 500),
  ];

  static const List<_AqiBreakpoint> _coBreakpoints = [
    _AqiBreakpoint(0.0, 4.4, 0, 50),
    _AqiBreakpoint(4.5, 9.4, 51, 100),
    _AqiBreakpoint(9.5, 12.4, 101, 150),
    _AqiBreakpoint(12.5, 15.4, 151, 200),
    _AqiBreakpoint(15.5, 30.4, 201, 300),
    _AqiBreakpoint(30.5, 50.4, 301, 500),
  ];

  static AqiResult calculate(double pm25, double pm10, double coPpm) {
    final int pm25Aqi = _computeSubIndex(pm25, _pm25Breakpoints);
    final int pm10Aqi = _computeSubIndex(pm10, _pm10Breakpoints);
    final int coAqi = _computeSubIndex(coPpm, _coBreakpoints);

    final int overallAqi = [pm25Aqi, pm10Aqi, coAqi]
        .reduce((a, b) => a > b ? a : b);
    return AqiResult(overallAqi, _categoryForAqi(overallAqi));
  }

  static Map<String, int> getSubIndices(double pm25, double pm10, double co) {
    return {
      'PM2.5': _computeSubIndex(pm25, _pm25Breakpoints),
      'PM10': _computeSubIndex(pm10, _pm10Breakpoints),
      'CO': _computeSubIndex(co, _coBreakpoints),
    };
  }

  static int _computeSubIndex(double c, List<_AqiBreakpoint> breakpoints) {
    final double cc = _truncate(c, breakpoints);
    for (final bp in breakpoints) {
      if (cc >= bp.cLow && cc <= bp.cHigh) {
        final double index = (bp.iHigh - bp.iLow) /
                (bp.cHigh - bp.cLow) *
                (cc - bp.cLow) +
            bp.iLow;
        return index.round();
      }
    }
    final bp = breakpoints.last;
    final double index = (bp.iHigh - bp.iLow) /
            (bp.cHigh - bp.cLow) *
            (cc - bp.cLow) +
        bp.iLow;
    return index.round().clamp(0, 500);
  }

  static double _truncate(double value, List<_AqiBreakpoint> breakpoints) {
    if (identical(breakpoints, _pm25Breakpoints) ||
        identical(breakpoints, _coBreakpoints)) {
      return (value * 10).truncate() / 10.0;
    }
    return value.truncate().toDouble();
  }

  static String _categoryForAqi(int aqi) {
    if (aqi <= 50) {
      return 'Good';
    }
    if (aqi <= 100) {
      return 'Moderate';
    }
    if (aqi <= 150) {
      return 'Unhealthy for Sensitive Groups';
    }
    if (aqi <= 200) {
      return 'Unhealthy';
    }
    if (aqi <= 300) {
      return 'Very Unhealthy';
    }
    return 'Hazardous';
  }
}

class _AqiBreakpoint {
  final double cLow;
  final double cHigh;
  final int iLow;
  final int iHigh;
  const _AqiBreakpoint(this.cLow, this.cHigh, this.iLow, this.iHigh);
}

class AqiResult {
  final int aqi;
  final String category;
  const AqiResult(this.aqi, this.category);
}

// ============================================================
//    INDOOR AIR QUALITY INDEX (Breeze Technologies style)
// ============================================================
class IndoorAqiCalculator {
  static int co2Score(double co2Ppm) {
    if (co2Ppm <= 400) {
      return 1;
    }
    if (co2Ppm <= 1000) {
      return 2;
    }
    if (co2Ppm <= 1500) {
      return 3;
    }
    if (co2Ppm <= 2000) {
      return 4;
    }
    if (co2Ppm <= 5000) {
      return 5;
    }
    return 6;
  }

  static int climateScore(double tempC, double humidity) {
    final int tempCol = tempC.round().clamp(15, 28);
    final int rhRow = (humidity / 10).round() * 10;
    const Map<int, Map<int, int>> matrix = {
      15: {0:6,10:6,20:6,30:6,40:6,50:6,60:5,70:5,80:5,90:6,100:6},
      16: {0:6,10:6,20:5,30:5,40:5,50:5,60:4,70:4,80:4,90:6,100:6},
      17: {0:6,10:5,20:5,30:5,40:5,50:5,60:3,70:3,80:2,90:6,100:6},
      18: {0:6,10:5,20:5,30:4,40:4,50:3,60:2,70:2,80:2,90:5,100:6},
      19: {0:6,10:5,20:5,30:4,40:3,50:2,60:1,70:2,80:2,90:5,100:6},
      20: {0:6,10:5,20:5,30:4,40:3,50:1,60:1,70:2,80:2,90:5,100:6},
      21: {0:6,10:5,20:4,30:4,40:1,50:1,60:1,70:2,80:2,90:5,100:6},
      22: {0:6,10:5,20:4,30:4,40:1,50:1,60:1,70:2,80:2,90:5,100:6},
      23: {0:6,10:5,20:4,30:4,40:2,50:1,60:1,70:2,80:3,90:5,100:6},
      24: {0:6,10:5,20:4,30:4,40:2,50:2,60:2,70:3,80:4,90:5,100:6},
      25: {0:6,10:5,20:4,30:4,40:3,50:3,60:3,70:4,80:5,90:5,100:6},
      26: {0:6,10:5,20:5,30:4,40:4,50:4,60:4,70:5,80:5,90:6,100:6},
      27: {0:6,10:6,20:5,30:5,40:5,50:5,60:5,70:5,80:6,90:6,100:6},
      28: {0:6,10:6,20:6,30:6,40:6,50:6,60:6,70:6,80:6,90:6,100:6},
    };
    return matrix[tempCol]?[rhRow] ?? 3;
  }

  static String labelForScore(int score) {
    switch (score) {
      case 1:
        return 'Excellent';
      case 2:
        return 'Fine';
      case 3:
        return 'Moderate';
      case 4:
        return 'Poor';
      case 5:
        return 'Very Poor';
      default:
        return 'Severe';
    }
  }

  static Map<String, dynamic> calculate(
      double co2Ppm, double tempC, double humidity) {
    final int co2S = co2Score(co2Ppm);
    final int cliS = climateScore(tempC, humidity);
    final int overall = co2S > cliS ? co2S : cliS;
    return {
      'score': overall,
      'label': labelForScore(overall),
      'co2_score': co2S,
      'climate_score': cliS,
    };
  }
}

// ============================================================
//                               ROOT
// ============================================================
class AQMSProRoot extends StatefulWidget {
  const AQMSProRoot({super.key});
  @override
  State<AQMSProRoot> createState() => _AQMSProRootState();
}

class _AQMSProRootState extends State<AQMSProRoot> {
  ThemeMode _themeMode = ThemeMode.dark;
  void toggleTheme() =>
      setState(() => _themeMode = _themeMode == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Karachi AQMS Pro',
      themeMode: _themeMode,
      theme: ThemeData.light(useMaterial3: true).copyWith(
        primaryColor: const Color(0xFF10B981),
        scaffoldBackgroundColor: const Color(0xFFF3F4F6),
        cardColor: Colors.white,
      ),
      darkTheme: ThemeData.dark(useMaterial3: true).copyWith(
        primaryColor: const Color(0xFF10B981),
        scaffoldBackgroundColor: const Color(0xFF111827),
        cardColor: const Color(0xFF1F2937),
      ),
      home: AQMSDashboard(
          toggleTheme: toggleTheme,
          isDarkMode: _themeMode == ThemeMode.dark),
    );
  }
}

// ============================================================
//                              DASHBOARD
// ============================================================
class AQMSDashboard extends StatefulWidget {
  final VoidCallback toggleTheme;
  final bool isDarkMode;
  const AQMSDashboard(
      {super.key, required this.toggleTheme, required this.isDarkMode});

  @override
  State<AQMSDashboard> createState() => _AQMSDashboardState();
}

class _AQMSDashboardState extends State<AQMSDashboard>
    with WidgetsBindingObserver {
  late MapController _mapController;

  late DatabaseReference _currentRef;
  late DatabaseReference _historyRef;
  StreamSubscription<DatabaseEvent>? _currentSubscription;
  StreamSubscription<DatabaseEvent>? _historySubscription;

  bool hasInternet = true;
  bool? _esp32Online;            // nullable: null = unknown, true/false = known
  Timer? _offlineTimer;
  late StreamSubscription<List<ConnectivityResult>> _connectivitySubscription;

  Map<String, double> liveData = {
    "temp": 0.0,
    "hum": 0.0,
    "pressure": 1013.0,
    "co2": 0.0,
    "co": 0.0,
    "pm1": 0.0,
    "pm25": 0.0,
    "pm10": 0.0,
    "lat": 24.8607,
    "lng": 67.0011
  };

  Map<String, bool> sensorErrors = {
    "temp": false,
    "hum": false,
    "pressure": false,
    "co": false,
    "co2": false,
    "pm1": false,
    "pm25": false,
    "pm10": false,
  };

  List<Map<String, dynamic>> historyData = [];
  final List<Map<String, dynamic>> _liveHistory = [];
  static const Duration _historyWindow = Duration(minutes: 60);

  final Map<String, List<double>> sensorLimits = {
    "temp": [32.0, 42.0, 60.0],
    "hum": [60.0, 80.0, 100.0],
    "pressure": [1013.0, 1050.0, 1100.0],
    "co2": [800.0, 1500.0, 5000.0],
    "co": [9.0, 50.0, 100.0],
    "pm1": [15.0, 50.0, 100.0],
    "pm25": [35.0, 150.0, 500.0],
    "pm10": [50.0, 200.0, 600.0],
  };

  bool? _lastEsp32Online;
  bool _serviceRunning = false;

  void _showLocalNotification(String title, String body) async {
    const AndroidNotificationDetails androidDetails =
        AndroidNotificationDetails(
      'aqms_channel',
      'AQMS Alerts',
      importance: Importance.high,
      priority: Priority.high,
    );
    const NotificationDetails details =
        NotificationDetails(android: androidDetails, iOS: null);
    await flutterLocalNotificationsPlugin.show(
      DateTime.now().millisecond,
      title,
      body,
      details,
    );
  }

  void _notifyIfEsp32Changed(bool newOnline) {
    if (_lastEsp32Online != null && _lastEsp32Online != newOnline) {
      if (newOnline) {
        _showLocalNotification(
            'ESP32 Connected', 'The air quality monitor is back online.');
      } else {
        _showLocalNotification(
            'ESP32 Disconnected', 'The air quality monitor has gone offline.');
      }
    }
    _lastEsp32Online = newOnline;
  }

  void _checkCriticalReadings() {
    List<String> alerts = [];
    if (liveData.containsKey("temp") && liveData["temp"]! >= 40.0) {
      alerts.add('Temperature: ${liveData["temp"]!.toStringAsFixed(1)} °C');
    }
    if (liveData.containsKey("hum") && liveData["hum"]! >= 85.0) {
      alerts.add('Humidity: ${liveData["hum"]!.toStringAsFixed(1)} %');
    }
    if (liveData.containsKey("co") && liveData["co"]! >= 9.0) {
      alerts.add('CO Level: ${liveData["co"]!.toStringAsFixed(1)} PPM');
    }
    if (liveData.containsKey("co2") && liveData["co2"]! >= 800.0) {
      alerts.add('CO₂ Level: ${liveData["co2"]!.toStringAsFixed(1)} PPM');
    }
    if (liveData.containsKey("pm1") && liveData["pm1"]! >= 50.0) {
      alerts.add('PM 1.0: ${liveData["pm1"]!.toStringAsFixed(1)} µg/m³');
    }
    if (liveData.containsKey("pm25") && liveData["pm25"]! >= 150.0) {
      alerts.add('PM 2.5: ${liveData["pm25"]!.toStringAsFixed(1)} µg/m³');
    }
    if (liveData.containsKey("pm10") && liveData["pm10"]! >= 250.0) {
      alerts.add('PM 10: ${liveData["pm10"]!.toStringAsFixed(1)} µg/m³');
    }

    if (alerts.isNotEmpty) {
      _showLocalNotification('High Sensor Readings', alerts.join(', '));
    }
  }

  // ---------- Sensor helpers ----------
  String getStatusText(String key, double value) {
    double good = sensorLimits[key]![0];
    double moderate = sensorLimits[key]![1];
    if (value <= good) {
      return "Good";
    }
    if (value <= moderate) {
      return "Moderate";
    }
    return "Poor";
  }

  Color getStatusColor(String key, double value) {
    double good = sensorLimits[key]![0];
    double moderate = sensorLimits[key]![1];
    if (value <= good) {
      return Colors.green;
    }
    if (value <= moderate) {
      return Colors.orange;
    }
    return Colors.red;
  }

  String getInterpretation(String key, double value) {
    switch (key) {
      case "temp":
        if (value <= 32) {
          return "Comfortable temperature";
        }
        if (value <= 42) {
          return "Warm, stay hydrated";
        }
        return "Very hot – avoid prolonged exposure";
      case "hum":
        if (value <= 60) {
          return "Comfortable humidity";
        }
        if (value <= 80) {
          return "A bit humid";
        }
        return "Very humid – use ventilation";
      case "co2":
        if (value <= 800) {
          return "Fresh air";
        }
        if (value <= 1500) {
          return "Stuffy – open a window";
        }
        return "Poor ventilation – ventilate now";
      case "co":
        if (value <= 9) {
          return "Safe level";
        }
        if (value <= 50) {
          return "Caution – may cause headaches";
        }
        return "Dangerous – ventilate immediately";
      case "pm25":
        if (value <= 35) {
          return "Good air quality";
        }
        if (value <= 150) {
          return "Unhealthy for sensitive groups";
        }
        return "Unhealthy – wear mask if going out";
      default:
        return "";
    }
  }

  final Map<String, Map<String, dynamic>> sensorMeta = {
    "temp": {"name": "Temperature", "unit": "°C", "icon": Icons.thermostat, "color": Colors.orange},
    "hum": {"name": "Humidity", "unit": "%", "icon": Icons.water_drop, "color": Colors.blueAccent},
    "pressure": {"name": "Air Pressure", "unit": "hPa", "icon": Icons.speed, "color": Colors.teal},
    "co2": {"name": "CO₂ Level", "unit": "PPM", "icon": Icons.co2, "color": Colors.green},
    "co": {"name": "Carbon Monoxide", "unit": "PPM", "icon": Icons.warning_amber, "color": Colors.redAccent},
    "pm1": {"name": "PM 1.0", "unit": "µg/m³", "icon": Icons.grain, "color": Colors.purpleAccent},
    "pm25": {"name": "PM 2.5", "unit": "µg/m³", "icon": Icons.blur_on, "color": Colors.purple},
    "pm10": {"name": "PM 10", "unit": "µg/m³", "icon": Icons.cloud, "color": Colors.deepPurple},
  };

  @override
  void initState() {
    super.initState();
    _mapController = MapController();
    WidgetsBinding.instance.addObserver(this);
    _checkConnectivity();
    _setupConnectivityListener();
    _setupFirebaseListeners();
    _esp32Online = null;            // unknown at start
    _startOfflineTimer();

    Future.delayed(const Duration(seconds: 2), _checkServiceStatus);
  }

  @override
  void dispose() {
    _offlineTimer?.cancel();
    _connectivitySubscription.cancel();
    _currentSubscription?.cancel();
    _historySubscription?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _checkServiceStatus() async {
    final service = FlutterBackgroundService();
    final running = await service.isRunning();
    if (mounted) {
      setState(() {
        _serviceRunning = running;
      });
    }
  }

  void _toggleMonitoring() async {
    final service = FlutterBackgroundService();
    if (_serviceRunning) {
      // Stop code – keep existing
    } else {
      service.startService();
      await Future.delayed(const Duration(seconds: 1));
      await flutterLocalNotificationsPlugin.cancel(888);

      const AndroidNotificationDetails foregroundDetails = AndroidNotificationDetails(
        'aqms_channel',
        'AQMS Service',
        icon: '@mipmap/ic_launcher',
        importance: Importance.high,
        priority: Priority.high,
        ongoing: true,
      );
      await flutterLocalNotificationsPlugin.show(
        888,
        'AQMS Monitoring',
        'System is watching for alerts...',
        const NotificationDetails(android: foregroundDetails),
      );

      const AndroidNotificationDetails stopButtonDetails = AndroidNotificationDetails(
        'aqms_channel',
        'AQMS Controls',
        icon: '@mipmap/ic_launcher',
        importance: Importance.high,
        priority: Priority.high,
        actions: <AndroidNotificationAction>[
          AndroidNotificationAction(
            'stop_service',
            'Stop Monitoring',
            showsUserInterface: false,
            cancelNotification: false,
          ),
        ],
      );
      await flutterLocalNotificationsPlugin.show(
        999,
        'Monitoring Active',
        'Tap here to stop monitoring',
        const NotificationDetails(android: stopButtonDetails),
      );

      if (mounted) {
        setState(() => _serviceRunning = true);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Monitoring started')),
        );
      }
    }
  }

  // ----- Connectivity & Firebase listeners -----
  void _checkConnectivity() async {
    final results = await Connectivity().checkConnectivity();
    _updateConnectivityStatus(results);
  }

  void _setupConnectivityListener() {
    _connectivitySubscription =
        Connectivity().onConnectivityChanged.listen((results) {
      _updateConnectivityStatus(results);
    });
  }

  void _updateConnectivityStatus(List<ConnectivityResult> results) {
    final wasConnected = hasInternet;
    bool isConnected =
        results.any((result) => result != ConnectivityResult.none);
    setState(() {
      hasInternet = isConnected;
      if (!isConnected) {
        _notifyIfEsp32Changed(false);
        _esp32Online = false;
        _resetSensorData();
        _offlineTimer?.cancel();
      } else if (!wasConnected) {
        // Internet just came back – unknown ESP32 state
        _esp32Online = null;
        _startOfflineTimer();
      }
    });
  }

  void _resetSensorData() {
    setState(() {
      liveData["temp"] = 0.0;
      liveData["hum"] = 0.0;
      liveData["pressure"] = 1013.0;
      liveData["co2"] = 0.0;
      liveData["co"] = 0.0;
      liveData["pm1"] = 0.0;
      liveData["pm25"] = 0.0;
      liveData["pm10"] = 0.0;
    });
  }

  void _startOfflineTimer() {
    _offlineTimer?.cancel();
    _offlineTimer = Timer(const Duration(seconds: 20), () {
      if (mounted && hasInternet && _esp32Online != true) {
        _notifyIfEsp32Changed(false);
        setState(() {
          _esp32Online = false;
          _resetSensorData();
        });
      }
    });
  }

  void _resetOfflineTimer() {
    _offlineTimer?.cancel();
    if (hasInternet) {
      _startOfflineTimer();
    }
  }

  void _setupFirebaseListeners() {
    FirebaseDatabase.instance.setPersistenceEnabled(true);
    FirebaseDatabase.instance.setPersistenceCacheSizeBytes(10000000);

    _currentRef = FirebaseDatabase.instance.ref('sensors/current');
    _currentSubscription = _currentRef.onValue.listen((event) {
      debugPrint('🔥 Current data received: ${event.snapshot.value}');
      final data = event.snapshot.value as Map<dynamic, dynamic>?;
      if (data != null && mounted) {
        // --- Check lastSeen for staleness (10 seconds threshold) ---
        final lastSeen = data['lastSeen'];
        if (lastSeen is num) {
          final nowSec = DateTime.now().millisecondsSinceEpoch / 1000.0;
          if ((nowSec - lastSeen.toDouble()).abs() > 10) {
            debugPrint('⏰ Data too old – treating as offline');
            setState(() {
              _esp32Online = false;
              _resetSensorData();
            });
            _notifyIfEsp32Changed(false);
            return;
          }
        }

        bool hasValidData = data['temperature'] != null || data['humidity'] != null;
        if (hasValidData) {
          setState(() {
            liveData["temp"] = (data['temperature'] ?? 0.0).toDouble();
            liveData["hum"] = (data['humidity'] ?? 0.0).toDouble();
            liveData["pressure"] = (data['pressure'] ?? 1013.0).toDouble();
            liveData["co2"] = (data['co2'] ?? 0.0).toDouble();
            liveData["co"] = (data['co'] ?? 0.0).toDouble();
            liveData["pm1"] = (data['pm1'] ?? 0.0).toDouble();
            liveData["pm25"] = (data['pm25'] ?? 0.0).toDouble();
            liveData["pm10"] = (data['pm10'] ?? 0.0).toDouble();
            liveData["lat"] = (data['lat'] ?? 24.8607).toDouble();
            liveData["lng"] = (data['lng'] ?? 67.0011).toDouble();

            final errors = data['sensor_errors'];
            if (errors != null) {
              sensorErrors["temp"] = errors['dht22'] ?? false;
              sensorErrors["hum"] = errors['dht22'] ?? false;
              sensorErrors["pressure"] = errors['bmp280'] ?? false;
              sensorErrors["co"] = errors['mq7_co'] ?? false;
              sensorErrors["co2"] = errors['mq135_co2'] ?? false;
              sensorErrors["pm1"] = errors['pms5003'] ?? false;
              sensorErrors["pm25"] = errors['pms5003'] ?? false;
              sensorErrors["pm10"] = errors['pms5003'] ?? false;
            }

            if (liveData["temp"] == -999.0 || liveData["hum"] == -999.0) {
              sensorErrors["temp"] = true;
              sensorErrors["hum"] = true;
            }
            if (liveData["pressure"] == -999.0) {
              sensorErrors["pressure"] = true;
            }
            if (liveData["co"] == -999.0) {
              sensorErrors["co"] = true;
            }
            if (liveData["co2"] == -999.0) {
              sensorErrors["co2"] = true;
            }
            if (liveData["pm1"] == -1.0 || liveData["pm25"] == -1.0 || liveData["pm10"] == -1.0) {
              sensorErrors["pm1"] = true;
              sensorErrors["pm25"] = true;
              sensorErrors["pm10"] = true;
            }

            _esp32Online = true;
            debugPrint('✅ Live data updated: $liveData');
          });

          _notifyIfEsp32Changed(true);
          _checkCriticalReadings();

          // --- Build rolling history buffer for live trend ---
          final now = DateTime.now();
          _liveHistory.add({
            'time': now,
            'temperature': liveData["temp"],
            'humidity': liveData["hum"],
            'pressure': liveData["pressure"],
            'co2': liveData["co2"],
            'co': liveData["co"],
            'pm1': liveData["pm1"],
            'pm25': liveData["pm25"],
            'pm10': liveData["pm10"],
            'lat': liveData["lat"],
            'lng': liveData["lng"],
          });
          _liveHistory.removeWhere(
              (entry) => now.difference(entry['time'] as DateTime) > _historyWindow);
          setState(() {
            historyData = List.from(_liveHistory);
          });

          double newLat = liveData['lat']!;
          double newLng = liveData['lng']!;
          if (newLat != 0.0 && newLng != 0.0) {
            _mapController.move(LatLng(newLat, newLng), _mapController.camera.zoom);
          }
          _resetOfflineTimer();
        }
      }
    }, onError: (error) {
      debugPrint('❌ Firebase error (current): $error');
      if (mounted) {
        _notifyIfEsp32Changed(false);
        setState(() => _esp32Online = false);
      }
    });

    // Keep history listener as optional fallback (not needed for live trend)
    _historyRef = FirebaseDatabase.instance.ref('sensors/history');
    _historySubscription =
        _historyRef.limitToLast(400).onValue.listen((event) {
      debugPrint('🔥 History data received: ${event.snapshot.value}');
      final data = event.snapshot.value as Map<dynamic, dynamic>?;
      if (data != null && mounted) {
        // You can still fill historyData with these if you want to merge
        // For now we rely on live buffer; this is just a fallback
        // (unchanged from original)
      }
    }, onError: (error) {
      debugPrint('❌ Firebase error (history): $error');
    });
  }

  // ---------- CSV export ----------
  void toast(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }

  Future<void> _exportToCSV() async {
    if (historyData.isEmpty) {
      toast("No data to export yet!");
      return;
    }
    try {
      List<List<dynamic>> rows = [];
      rows.add([
        "Timestamp (Full)",
        "Temp (°C)",
        "Hum (%)",
        "Pressure (hPa)",
        "CO₂ (ppm)",
        "CO (ppm)",
        "PM1 (µg/m³)",
        "PM2.5 (µg/m³)",
        "PM10 (µg/m³)",
        "Lat",
        "Lng"
      ]);

      double lastValidLat = 0.0;
      double lastValidLng = 0.0;

      for (var entry in historyData) {
        DateTime t = entry['time'];
        String fullDateTime =
            "${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')} "
            "${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}";

        double temp = (entry['temperature'] ?? 0.0).toDouble();
        double hum = (entry['humidity'] ?? 0.0).toDouble();
        double pressure = (entry['pressure'] ?? 1013.0).toDouble();
        double co2 = (entry['co2'] ?? 0.0).toDouble();
        double co = (entry['co'] ?? 0.0).toDouble();
        int pm1 = (entry['pm1'] ?? 0).toInt();
        int pm25 = (entry['pm25'] ?? 0).toInt();
        int pm10 = (entry['pm10'] ?? 0).toInt();

        double lat = (entry['lat'] ?? 0.0).toDouble();
        double lng = (entry['lng'] ?? 0.0).toDouble();
        if (lat != 0.0 || lng != 0.0) {
          lastValidLat = lat;
          lastValidLng = lng;
        } else {
          lat = lastValidLat;
          lng = lastValidLng;
        }

        rows.add([
          fullDateTime,
          temp == -999.0 ? "ERROR" : temp.toStringAsFixed(1),
          hum == -999.0 ? "ERROR" : hum.toStringAsFixed(1),
          pressure == -999.0 ? "ERROR" : pressure.toStringAsFixed(1),
          co2 == -999.0 ? "ERROR" : co2.toStringAsFixed(1),
          co == -999.0 ? "ERROR" : co.toStringAsFixed(1),
          pm1 == -1 ? "ERROR" : pm1.toString(),
          pm25 == -1 ? "ERROR" : pm25.toString(),
          pm10 == -1 ? "ERROR" : pm10.toString(),
          lat,
          lng,
        ]);
      }

      String csv = const ListToCsvConverter().convert(rows);
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/aqms_data_${DateTime.now().millisecondsSinceEpoch}.csv');
      await file.writeAsString(csv);
      await Share.shareXFiles([XFile(file.path)], text: 'AQMS Sensor Data Export');
    } catch (e) {
      toast("Export failed: $e");
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) {
          return;
        }
        final shouldExit = await _showExitDialog(context);
        if (shouldExit) {
          SystemNavigator.pop();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          elevation: 0,
          backgroundColor: Theme.of(context).cardColor,
          title: const Text("KARACHI AQMS"),
          actions: [
            IconButton(icon: const Icon(Icons.info_outline, color: Colors.grey), onPressed: () => _showHelpDialog(context)),
            IconButton(icon: const Icon(Icons.download, color: Colors.blue), tooltip: "Download CSV", onPressed: _exportToCSV),
            IconButton(icon: Icon(widget.isDarkMode ? Icons.light_mode : Icons.dark_mode), onPressed: widget.toggleTheme),
            const SizedBox(width: 8),
          ],
        ),
        drawer: _buildDrawer(),
        body: _buildDashboard(),
      ),
    );
  }

  Future<bool> _showExitDialog(BuildContext context) async {
    return await showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Exit App'),
            content: const Text('Do you want to close the app?'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Back')),
              TextButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('OK'),
              ),
            ],
          ),
        ) ??
        false;
  }

  void _showHelpDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Understanding the readings'),
        content: SingleChildScrollView(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            _helpItem("🌡️ Temperature (°C)", "Good: < 32°C, Moderate: 32-42°C, Poor: > 42°C"),
            _helpItem("💧 Humidity (%)", "Good: < 60%, Moderate: 60-80%, Poor: > 80%"),
            _helpItem("🫁 CO₂ (PPM)", "Good: < 800 (fresh air), Moderate: 800-1500 (stuffy), Poor: > 1500 (ventilate)"),
            _helpItem("⚠️ Carbon Monoxide (PPM)", "Safe: < 9, Caution: 9-50, Dangerous: > 50"),
            _helpItem("🌫️ PM2.5 (µg/m³)", "Good: < 35, Moderate: 35-150, Unhealthy: > 150"),
            const SizedBox(height: 8),
            const Text("The live trend graph shows changes over the last 60 minutes.", style: TextStyle(fontSize: 12)),
          ]),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text("Got it"))],
      ),
    );
  }

  Widget _helpItem(String title, String description) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
        Text(description, style: const TextStyle(fontSize: 12)),
        const Divider(),
      ]),
    );
  }

  Widget _buildCompactSubAqi(String label, int aqi, Color parentColor) {
    Color subColor;
    if (aqi <= 50) {
      subColor = Colors.green;
    } else if (aqi <= 100) {
      subColor = Colors.orange;
    } else {
      subColor = Colors.red;
    }
    return Column(
      children: [
        Text(label, style: TextStyle(fontSize: 11, color: Colors.grey)),
        const SizedBox(height: 2),
        Text('$aqi', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: subColor)),
      ],
    );
  }

  Widget _buildEpaAqiCard(AqiResult overall, Map<String, int> subAqi) {
    Color color;
    if (overall.aqi <= 50) {
      color = Colors.green;
    } else if (overall.aqi <= 100) {
      color = Colors.orange;
    } else {
      color = Colors.red;
    }
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color, width: 1.5),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(children: [
            Expanded(child: Text('Air Quality Index (AQI)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16))),
            const SizedBox(width: 8),
            Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text('${overall.aqi}', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 32, color: color)),
              Text(overall.category, style: TextStyle(fontSize: 13, color: color)),
            ]),
          ]),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _buildCompactSubAqi('PM2.5', subAqi['PM2.5']!, color),
              _buildCompactSubAqi('PM10', subAqi['PM10']!, color),
              _buildCompactSubAqi('CO', subAqi['CO']!, color),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildIndoorAqiCard(Map<String, dynamic> indoor) {
    final int score = indoor['score'];
    final String label = indoor['label'];
    final int co2S = indoor['co2_score'];
    final int cliS = indoor['climate_score'];
    Color color;
    if (score <= 2) {
      color = Colors.green;
    } else if (score <= 4) {
      color = Colors.orange;
    } else {
      color = Colors.red;
    }
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color, width: 1.5),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(children: [
            Expanded(child: Text('Indoor AQI', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16))),
            const SizedBox(width: 8),
            Flexible(child: Text(label, style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 18), textAlign: TextAlign.right, maxLines: 2)),
          ]),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(child: _buildIndoorSubScore('CO₂', co2S, color)),
            Expanded(child: _buildIndoorSubScore('Climate', cliS, color)),
          ]),
          const SizedBox(height: 12),
          Text(_getIndoorAdvice(label), style: TextStyle(color: color, fontSize: 13), textAlign: TextAlign.center),
        ],
      ),
    );
  }

  Widget _buildIndoorSubScore(String label, int score, Color parentColor) {
    Color subColor;
    if (score <= 2) {
      subColor = Colors.green;
    } else if (score <= 4) {
      subColor = Colors.orange;
    } else {
      subColor = Colors.red;
    }
    return Column(children: [
      Text(label, style: TextStyle(fontSize: 12, color: Colors.grey)),
      const SizedBox(height: 4),
      Text(IndoorAqiCalculator.labelForScore(score), style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: subColor)),
    ]);
  }

  String _getIndoorAdvice(String label) {
    switch (label) {
      case 'Excellent':
        return 'Ideal indoor conditions.';
      case 'Fine':
        return 'Comfortable; ventilation is good.';
      case 'Moderate':
        return 'Consider opening a window to improve air.';
      case 'Poor':
        return 'Poor ventilation – increase fresh air.';
      case 'Very Poor':
        return 'Heavily polluted indoor air. Act now.';
      default:
        return 'Severe indoor pollution! Evacuate if possible.';
    }
  }

  Widget _buildDashboard() {
    final AqiResult overallAqi = AqiCalculator.calculate(
      liveData["pm25"]!,
      liveData["pm10"]!,
      liveData["co"]!,
    );
    final Map<String, int> subAqi = AqiCalculator.getSubIndices(
      liveData["pm25"]!,
      liveData["pm10"]!,
      liveData["co"]!,
    );
    final Map<String, dynamic> indoorAqi = IndoorAqiCalculator.calculate(
      liveData["co2"]!,
      liveData["temp"]!,
      liveData["hum"]!,
    );

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _buildStatusBanner(),
        const SizedBox(height: 8),
        ElevatedButton.icon(
          onPressed: _toggleMonitoring,
          icon: Icon(_serviceRunning ? Icons.stop : Icons.play_arrow),
          label: Text(_serviceRunning ? 'Stop Monitoring' : 'Start Monitoring'),
          style: ElevatedButton.styleFrom(
            backgroundColor: _serviceRunning ? Colors.red : Colors.green,
            foregroundColor: Colors.white,
          ),
        ),
        const SizedBox(height: 12),
        _buildEpaAqiCard(overallAqi, subAqi),
        const SizedBox(height: 12),
        _buildIndoorAqiCard(indoorAqi),
        const SizedBox(height: 16),
        _buildMapSection(),
        const SizedBox(height: 24),
        Text("Environmental Sensors",
            style: GoogleFonts.outfit(fontSize: 18, fontWeight: FontWeight.bold)),
        const SizedBox(height: 12),
        GridView.count(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          crossAxisCount: 2,
          childAspectRatio: 0.75,
          crossAxisSpacing: 12,
          mainAxisSpacing: 12,
          children: [
            _gridSensorCard("temp"),
            _gridSensorCard("hum"),
            _gridSensorCard("co2"),
            _gridSensorCard("co"),
            _gridSensorCard("pm1"),
            _gridSensorCard("pm25"),
            _gridSensorCard("pm10"),
            _gridSensorCard("pressure"),
          ],
        ),
        const SizedBox(height: 20),
      ],
    );
  }

  Widget _gridSensorCard(String key) {
    final meta = sensorMeta[key]!;
    double val = liveData[key] ?? 0.0;
    bool hasError = sensorErrors[key] ?? false;

    if (!hasError) {
      if ((key == "temp" || key == "hum" || key == "pressure" || key == "co" || key == "co2") && val == -999.0) {
        hasError = true;
      } else if ((key == "pm1" || key == "pm25" || key == "pm10") && val == -1.0) {
        hasError = true;
      }
    }

    String displayValue;
    String status;
    Color statusColor;
    String interpretation;

    if (hasError) {
      displayValue = "Out of order";
      status = "Faulty";
      statusColor = Colors.grey;
      interpretation = "Sensor not responding – check wiring/power";
    } else if (_esp32Online == null) {
      displayValue = "---";
      status = "Connecting…";
      statusColor = Colors.grey;
      interpretation = "Waiting for data...";
    } else if (!_esp32Online!) {
      displayValue = "---";
      status = "Offline";
      statusColor = Colors.grey;
      interpretation = "Waiting for data...";
    } else {
      displayValue = val.toStringAsFixed(1);
      status = getStatusText(key, val);
      statusColor = getStatusColor(key, val);
      interpretation = getInterpretation(key, val);
    }

    return GestureDetector(
      onTap: () {
        Navigator.push(context, MaterialPageRoute(builder: (context) => SensorDetailPage(
          keyParam: key,
          sensorMeta: meta,
          sensorLimits: sensorLimits[key] ?? [50.0, 80.0, 100.0],
          currentValue: val,
          status: status,
          statusColor: statusColor,
          interpretation: interpretation,
          historyData: historyData,
          esp32Online: _esp32Online ?? false,
          liveData: liveData,
          sensorErrors: sensorErrors,
        )));
      },
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Theme.of(context).cardColor,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: statusColor.withValues(alpha: 0.5), width: 1.5),
          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 6, offset: const Offset(0, 2))],
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Icon(meta['icon'], color: meta['color'], size: 28),
            Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2), decoration: BoxDecoration(color: statusColor.withValues(alpha: 0.2), borderRadius: BorderRadius.circular(12)), child: Text(status, style: TextStyle(color: statusColor, fontSize: 12, fontWeight: FontWeight.bold))),
          ]),
          const SizedBox(height: 8),
          Text(meta['name'], style: GoogleFonts.outfit(fontSize: 16, fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text(
            displayValue,
            style: GoogleFonts.outfit(
              fontSize: 28,
              fontWeight: FontWeight.bold,
              color: hasError ? Colors.grey : Theme.of(context).textTheme.bodyLarge?.color,
            ),
          ),
          const SizedBox(height: 8),
          Text(interpretation, style: TextStyle(fontSize: 11, color: hasError ? Colors.grey : Colors.grey), maxLines: 2, overflow: TextOverflow.ellipsis),
        ]),
      ),
    );
  }

  Widget _buildStatusBanner() {
    String statusText, statusSubtext;
    Color statusColor;
    IconData statusIcon;
    if (!hasInternet) {
      statusText = "No Internet Connection";
      statusSubtext = "Please check your Wi‑Fi or mobile data";
      statusColor = Colors.orange;
      statusIcon = Icons.wifi_off;
    } else if (_esp32Online == null) {
      statusText = "Connecting…";
      statusSubtext = "Trying to reach ESP32";
      statusColor = Colors.orange;
      statusIcon = Icons.wifi;
    } else if (!_esp32Online!) {
      statusText = "ESP32 Offline";
      statusSubtext = "Device is not sending data";
      statusColor = Colors.red;
      statusIcon = Icons.sensors_off;
    } else {
      statusText = "System Online";
      statusSubtext = "Receiving live telemetry";
      statusColor = Colors.green;
      statusIcon = Icons.wifi;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(color: statusColor.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(12), border: Border.all(color: statusColor, width: 1)),
      child: Row(children: [
        Icon(statusIcon, color: statusColor),
        const SizedBox(width: 12),
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(statusText, style: GoogleFonts.outfit(fontWeight: FontWeight.bold)),
          Text(statusSubtext, style: const TextStyle(fontSize: 10)),
        ]),
        const Spacer(),
        if (_esp32Online == true && hasInternet)
          Text("LIVE", style: TextStyle(color: Colors.green, fontWeight: FontWeight.bold))
              .animate(onPlay: (c) => c.repeat()).fadeIn(duration: 500.ms).fadeOut(delay: 500.ms),
      ]),
    );
  }

  Widget _buildMapSection() {
    double lat = liveData['lat']!;
    double lng = liveData['lng']!;
    if (lat == 0.0 && lng == 0.0) {
      lat = 24.8607;
      lng = 67.0011;
    }
    return Container(
      height: 180,
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(20), boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.1), blurRadius: 10)]),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: Stack(children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(initialCenter: LatLng(lat, lng), initialZoom: 14),
            children: [
              TileLayer(urlTemplate: 'https://{s}.basemaps.cartocdn.com/light_all/{z}/{x}/{y}.png', subdomains: ['a', 'b', 'c']),
              MarkerLayer(markers: [Marker(point: LatLng(lat, lng), child: const Icon(Icons.location_on, color: Colors.red, size: 40))]),
            ],
          ),
          Positioned(top: 10, right: 10, child: Material(color: Colors.white70, borderRadius: BorderRadius.circular(30), elevation: 2, child: InkWell(
            onTap: () {
              double newLat = liveData['lat']!;
              double newLng = liveData['lng']!;
              if (newLat == 0.0 && newLng == 0.0) {
                newLat = 24.8607;
                newLng = 67.0011;
              }
              _mapController.move(LatLng(newLat, newLng), _mapController.camera.zoom);
            },
            child: const Padding(padding: EdgeInsets.all(8.0), child: Icon(Icons.my_location, color: Colors.black87, size: 20)),
          ))),
          Positioned(bottom: 10, right: 10, child: Container(padding: const EdgeInsets.all(8), decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(8)), child: Text("Lat: ${lat.toStringAsFixed(4)}\nLng: ${lng.toStringAsFixed(4)}", style: const TextStyle(color: Colors.white, fontSize: 10)))),
          Positioned(bottom: 5, left: 5, child: Container(padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2), color: Colors.black54, child: const Text('© CartoDB, © OpenStreetMap contributors', style: TextStyle(color: Colors.white70, fontSize: 8)))),
        ]),
      ),
    );
  }

  Widget _buildDrawer() {
    return Drawer(
      child: ListView(padding: EdgeInsets.zero, children: [
        DrawerHeader(decoration: BoxDecoration(color: Theme.of(context).primaryColor), child: const Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(Icons.air, size: 60, color: Colors.white),
          SizedBox(height: 10),
          Text("AQMS Pro", style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
        ])),
        ListTile(leading: const Icon(Icons.dashboard), title: const Text("Dashboard"), onTap: () => Navigator.pop(context)),
        const Divider(),
        ...sensorMeta.entries.map((e) => ListTile(
          leading: Icon(e.value['icon'], color: e.value['color']),
          title: Text(e.value['name']),
          onTap: () {
            Navigator.pop(context);
            final key = e.key;
            final meta = e.value;
            final val = liveData[key] ?? 0.0;
            final status = getStatusText(key, val);
            final statusColor = getStatusColor(key, val);
            final interpretation = getInterpretation(key, val);
            Navigator.push(context, MaterialPageRoute(builder: (context) => SensorDetailPage(
              keyParam: key,
              sensorMeta: meta,
              sensorLimits: sensorLimits[key] ?? [50.0, 80.0, 100.0],
              currentValue: val,
              status: status,
              statusColor: statusColor,
              interpretation: interpretation,
              historyData: historyData,
              esp32Online: _esp32Online ?? false,
              liveData: liveData,
              sensorErrors: sensorErrors,
            )));
          },
        )),
      ]),
    );
  }
}

// ============================================================
//                        SENSOR DETAIL PAGE
// ============================================================
class SensorDetailPage extends StatefulWidget {
  final String keyParam;
  final Map<String, dynamic> sensorMeta;
  final List<double> sensorLimits;
  final double currentValue;
  final String status;
  final Color statusColor;
  final String interpretation;
  final List<Map<String, dynamic>> historyData;
  final bool esp32Online;
  final Map<String, double> liveData;
  final Map<String, bool> sensorErrors;

  const SensorDetailPage({
    super.key,
    required this.keyParam,
    required this.sensorMeta,
    required this.sensorLimits,
    required this.currentValue,
    required this.status,
    required this.statusColor,
    required this.interpretation,
    required this.historyData,
    required this.esp32Online,
    required this.liveData,
    required this.sensorErrors,
  });

  @override
  State<SensorDetailPage> createState() => _SensorDetailPageState();
}

class _SensorDetailPageState extends State<SensorDetailPage> {
  Timer? _tooltipTimer;
  OverlayEntry? _tooltipOverlay;
  Timer? _dotTimer;
  int? _selectedIndex;
  final GlobalKey _chartKey = GlobalKey();
  double minY = 0, maxY = 0;
  Timer? _refreshTimer;
  final ScrollController _scrollController = ScrollController();

  String _formatSeconds(double seconds) {
    final dt = DateTime.fromMillisecondsSinceEpoch((seconds * 1000).round());
    return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  double _calculateLeftAxisWidth(double minY, double maxY, double interval) {
    double maxWidth = 0;
    final textStyle = const TextStyle(fontSize: 10);
    final textPainter = TextPainter(textDirection: TextDirection.ltr);
    for (double val = minY; val <= maxY + interval / 2; val += interval) {
      final label = val.toStringAsFixed(1);
      textPainter.text = TextSpan(text: label, style: textStyle);
      textPainter.layout();
      if (textPainter.width > maxWidth) {
        maxWidth = textPainter.width;
      }
    }
    return maxWidth + 16;
  }

  int? _findSpotIndex(LineBarSpot spot) {
    final barData = spot.bar;
    final spotsList = barData.spots;
    for (int i = 0; i < spotsList.length; i++) {
      if ((spotsList[i].x - spot.x).abs() < 0.5) {
        return i;
      }
    }
    return null;
  }

  void _showTooltip(LineBarSpot spot) {
    _tooltipTimer?.cancel();
    _tooltipOverlay?.remove();

    final idx = _findSpotIndex(spot);
    if (idx == null) {
      return;
    }

    final meta = widget.sensorMeta;
    setState(() {
      _selectedIndex = idx;
    });

    _dotTimer?.cancel();
    _dotTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) {
        setState(() {
          _selectedIndex = null;
        });
      }
    });

    final RenderBox? box = _chartKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) {
      return;
    }

    final Offset chartPosition = box.localToGlobal(Offset.zero);
    final double range = maxY - minY;
    final double touchY = range == 0 ? 0 : (1 - (spot.y - minY) / range) * box.size.height;

    double tooltipTop = chartPosition.dy + touchY - 85;
    double tooltipLeft = chartPosition.dx + (spot.x / box.size.width) * box.size.width - 50;

    if (tooltipLeft < 10) {
      tooltipLeft = 10;
    }
    if (tooltipLeft + 100 > MediaQuery.of(context).size.width) {
      tooltipLeft = MediaQuery.of(context).size.width - 110;
    }
    if (tooltipTop < 0) {
      tooltipTop = 5;
    }

    final timeStr = _formatSeconds(spot.x);

    _tooltipOverlay = OverlayEntry(
      builder: (context) => Positioned(
        left: tooltipLeft,
        top: tooltipTop,
        child: Material(
          color: Colors.transparent,
          child: Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(8)),
            child: Text(
              '${meta['name']}: ${spot.y.toStringAsFixed(1)} ${meta['unit']}\nTime: $timeStr',
              style: const TextStyle(color: Colors.white, fontSize: 12),
            ),
          ),
        ),
      ),
    );
    Overlay.of(context).insert(_tooltipOverlay!);

    _tooltipTimer = Timer(const Duration(seconds: 3), () {
      _tooltipOverlay?.remove();
      _tooltipOverlay = null;
    });
  }

  @override
  void initState() {
    super.initState();
    _refreshTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      if (mounted) {
        setState(() {});
      }
    });
  }

  @override
  void didUpdateWidget(SensorDetailPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.historyData != widget.historyData) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    _tooltipTimer?.cancel();
    _tooltipOverlay?.remove();
    _dotTimer?.cancel();
    _refreshTimer?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final meta = widget.sensorMeta;
    final limits = widget.sensorLimits;
    final value = widget.currentValue;
    final statusText = widget.status;
    final statusCol = widget.statusColor;
    final interp = widget.interpretation;

    bool isFaulty = widget.sensorErrors[widget.keyParam] ?? false;
    if (!isFaulty) {
      if ((widget.keyParam == "temp" || widget.keyParam == "hum" || widget.keyParam == "pressure" ||
           widget.keyParam == "co" || widget.keyParam == "co2") && value == -999.0) {
        isFaulty = true;
      } else if ((widget.keyParam == "pm1" || widget.keyParam == "pm25" || widget.keyParam == "pm10") && value == -1.0) {
        isFaulty = true;
      }
    }

    if (isFaulty) {
      return Scaffold(
        appBar: AppBar(title: Text(meta['name'])),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.sensor_occupied, size: 80, color: Colors.red),
              const SizedBox(height: 20),
              Text(
                "Sensor Out of Order",
                style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.red),
              ),
              const SizedBox(height: 10),
              Text(
                "Please check the sensor connection and power.",
                style: const TextStyle(fontSize: 16),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
              ElevatedButton.icon(
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.arrow_back),
                label: const Text("Back to Dashboard"),
              ),
            ],
          ),
        ),
      );
    }

    final bool staleWarning = !widget.esp32Online && widget.historyData.isNotEmpty;

    final double nowSeconds = DateTime.now().millisecondsSinceEpoch / 1000.0;
    const double lookbackSeconds = 3600;

    List<FlSpot> spots = [];
    double minX = nowSeconds - lookbackSeconds;
    double maxX = nowSeconds;
    double niceInterval = 1.0;
    minY = 0;
    maxY = 0;

    if (widget.historyData.isNotEmpty) {
      for (int i = 0; i < widget.historyData.length; i++) {
        final entry = widget.historyData[i];
        final ts = entry['time'];
        if (ts is! DateTime) {
          continue;
        }
        final double x = ts.millisecondsSinceEpoch / 1000.0;
        if (x < minX) {
          continue;
        }

        String historyKey = widget.keyParam;
        if (widget.keyParam == 'temp') {
          historyKey = 'temperature';
        }
        if (widget.keyParam == 'hum') {
          historyKey = 'humidity';
        }
        final num val = (entry[historyKey] ?? 0.0) as num;
        final double y = val.toDouble();

        spots.add(FlSpot(x, y));
      }

      if (spots.isNotEmpty) {
        minY = maxY = spots.first.y;
        for (final spot in spots) {
          if (spot.y < minY) {
            minY = spot.y;
          }
          if (spot.y > maxY) {
            maxY = spot.y;
          }
        }
        double yRange = maxY - minY;
        if (yRange > 0) {
          double margin = yRange * 0.05;
          minY -= margin;
          maxY += margin;
        } else {
          minY -= 0.5;
          maxY += 0.5;
        }

        yRange = maxY - minY;
        if (yRange == 0) {
          yRange = 1.0;
        }
        double rawInterval = yRange / 5;
        if (rawInterval <= 0.1) {
          niceInterval = 0.1;
        } else if (rawInterval <= 0.2) {
          niceInterval = 0.2;
        } else if (rawInterval <= 0.5) {
          niceInterval = 0.5;
        } else if (rawInterval <= 1.0) {
          niceInterval = 1.0;
        } else if (rawInterval <= 2.0) {
          niceInterval = 2.0;
        } else if (rawInterval <= 5.0) {
          niceInterval = 5.0;
        } else if (rawInterval <= 10.0) {
          niceInterval = 10.0;
        } else if (rawInterval <= 20.0) {
          niceInterval = 20.0;
        } else if (rawInterval <= 50.0) {
          niceInterval = 50.0;
        } else {
          niceInterval = 100.0;
        }

        minY = (minY / niceInterval).floor() * niceInterval;
        maxY = (maxY / niceInterval).ceil() * niceInterval;
      }
    }

    final leftAxisWidth = _calculateLeftAxisWidth(minY, maxY, niceInterval);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
      }
    });

    return Scaffold(
      appBar: AppBar(title: Text(meta['name'])),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            if (staleWarning)
              Container(
                margin: const EdgeInsets.only(bottom: 16),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.orange.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.orange, width: 1),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.warning_amber, color: Colors.orange),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        "Device is offline. Showing last known data (may be stale).",
                        style: const TextStyle(color: Colors.orange, fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Theme.of(context).cardColor,
                borderRadius: BorderRadius.circular(24),
              ),
              child: Column(
                children: [
                  SizedBox(
                    height: 250,
                    child: SfRadialGauge(
                      axes: [
                        RadialAxis(
                          minimum: 0,
                          maximum: limits[2],
                          axisLineStyle: const AxisLineStyle(thickness: 20),
                          ranges: [
                            GaugeRange(startValue: 0, endValue: limits[0], color: Colors.green, startWidth: 20, endWidth: 20),
                            GaugeRange(startValue: limits[0], endValue: limits[1], color: Colors.orange, startWidth: 20, endWidth: 20),
                            GaugeRange(startValue: limits[1], endValue: limits[2], color: Colors.red, startWidth: 20, endWidth: 20),
                          ],
                          pointers: <GaugePointer>[NeedlePointer(value: value)],
                          annotations: [
                            GaugeAnnotation(
                              widget: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(value.toStringAsFixed(1), style: const TextStyle(fontSize: 32, fontWeight: FontWeight.bold)),
                                  Text(meta['unit'], style: const TextStyle(fontSize: 14, color: Colors.grey)),
                                ],
                              ),
                              angle: 90,
                              positionFactor: 0.5,
                            )
                          ],
                        )
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    "Current: $value ${meta['unit']} - $statusText",
                    style: TextStyle(color: statusCol, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  Text(interp, textAlign: TextAlign.center, style: TextStyle(fontSize: 12, color: Colors.grey)),
                ],
              ),
            ),
            const SizedBox(height: 20),
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Theme.of(context).cardColor,
                borderRadius: BorderRadius.circular(24),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text("Live Trend",
                      style: GoogleFonts.outfit(
                          fontSize: 16, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 20),
                  Container(
                    height: 220,
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.white, width: 1),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (spots.isNotEmpty)
                          Container(
                            width: leftAxisWidth,
                            padding: const EdgeInsets.only(right: 12, left: 4),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(maxY.toStringAsFixed(1),
                                    style: const TextStyle(fontSize: 10),
                                    softWrap: false,
                                    overflow: TextOverflow.visible),
                                const Spacer(),
                                Text(((minY + maxY) / 2).toStringAsFixed(1),
                                    style: const TextStyle(fontSize: 10),
                                    softWrap: false,
                                    overflow: TextOverflow.visible),
                                const Spacer(),
                                Text(minY.toStringAsFixed(1),
                                    style: const TextStyle(fontSize: 10),
                                    softWrap: false,
                                    overflow: TextOverflow.visible),
                              ],
                            ),
                          ),
                        Expanded(
                          child: SingleChildScrollView(
                            controller: _scrollController,
                            scrollDirection: Axis.horizontal,
                            child: Padding(
                              padding: const EdgeInsets.only(right: 20),
                              child: SizedBox(
                                width: max(
                                  MediaQuery.of(context).size.width - 40 - leftAxisWidth,
                                  (spots.length * 14.0) + 70,
                                ),
                                height: 220,
                                child: spots.isEmpty
                                    ? const Center(
                                        child: Text("No data in the last 60 minutes"))
                                    : LineChart(
                                        key: _chartKey,
                                        LineChartData(
                                          gridData: const FlGridData(show: false),
                                          minX: minX,
                                          maxX: maxX,
                                          minY: minY,
                                          maxY: maxY,
                                          lineTouchData: LineTouchData(
                                            handleBuiltInTouches: true,
                                            touchCallback: (event, response) {
                                              if (response?.lineBarSpots != null &&
                                                  response!.lineBarSpots!.isNotEmpty) {
                                                _showTooltip(response.lineBarSpots!.first);
                                              }
                                            },
                                          ),
                                          titlesData: FlTitlesData(
                                            leftTitles: const AxisTitles(
                                                sideTitles: SideTitles(showTitles: false)),
                                            bottomTitles: AxisTitles(
                                              sideTitles: SideTitles(
                                                showTitles: true,
                                                reservedSize: 40,
                                                interval: 300,
                                                getTitlesWidget: (value, meta) =>
                                                    Text(_formatSeconds(value),
                                                        style: const TextStyle(fontSize: 10)),
                                              ),
                                            ),
                                            topTitles: const AxisTitles(
                                                sideTitles: SideTitles(showTitles: false)),
                                            rightTitles: const AxisTitles(
                                                sideTitles: SideTitles(showTitles: false)),
                                          ),
                                          lineBarsData: [
                                            LineChartBarData(
                                              spots: spots,
                                              isCurved: true,
                                              color: meta['color'],
                                              barWidth: 3,
                                              dotData: FlDotData(
                                                show: true,
                                                getDotPainter: (spot, percent, barData, index) {
                                                  final isSelected = index == _selectedIndex;
                                                  return FlDotCirclePainter(
                                                    radius: isSelected ? 6 : 0,
                                                    color: (meta['color'] as Color)
                                                        .withValues(alpha: 0.8),
                                                    strokeWidth: isSelected ? 3 : 0,
                                                    strokeColor: Colors.white,
                                                  );
                                                },
                                              ),
                                              belowBarData: BarAreaData(
                                                show: true,
                                                color: (meta['color'] as Color)
                                                    .withValues(alpha: 0.2),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            ElevatedButton.icon(
              onPressed: () => Navigator.pop(context),
              icon: const Icon(Icons.arrow_back),
              label: const Text("Back to Dashboard"),
              style: ElevatedButton.styleFrom(
                minimumSize: const Size(double.infinity, 55),
                backgroundColor: Theme.of(context).primaryColor,
                foregroundColor: Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }
}