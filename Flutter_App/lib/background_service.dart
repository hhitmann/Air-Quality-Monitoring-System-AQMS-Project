// lib/background_service.dart
import 'dart:async';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

final FlutterLocalNotificationsPlugin _localNotifications =
    FlutterLocalNotificationsPlugin();

@pragma('vm:entry-point')
Future<void> onServiceStart(ServiceInstance service) async {
  await Firebase.initializeApp();

  // Helper for alert notifications (high readings, connectivity)
  void showAlert(String title, String body) async {
    const AndroidNotificationDetails alertDetails = AndroidNotificationDetails(
      'aqms_channel',
      'AQMS Alerts',
      importance: Importance.high,
      priority: Priority.high,
      channelShowBadge: true,
    );
    await _localNotifications.show(
      DateTime.now().millisecond,
      title,
      body,
      const NotificationDetails(android: alertDetails),
    );
  }

  // Firebase listeners (unchanged)
  final DatabaseReference currentRef =
      FirebaseDatabase.instance.ref('sensors/current');

  Map<String, double> liveData = {
    "temp": 0.0, "hum": 0.0, "pressure": 1013.0,
    "co2": 0.0, "co": 0.0,
    "pm1": 0.0, "pm25": 0.0, "pm10": 0.0,
  };

  final Map<String, double> criticalLimits = {
    "temp": 40.0, "hum": 85.0, "co": 9.0, "co2": 800.0,
    "pm1": 50.0, "pm25": 150.0, "pm10": 250.0,
  };

  bool? lastOnline;
  Timer? offlineTimer;

  void checkConnectivity(bool online) {
    if (lastOnline != null && lastOnline != online) {
      if (online) {
        showAlert('ESP32 Connected', 'The air quality monitor is back online.');
      } else {
        showAlert('ESP32 Disconnected', 'The air quality monitor has gone offline.');
      }
    }
    lastOnline = online;
  }

  void checkThresholds() {
    List<String> alerts = [];
    criticalLimits.forEach((key, limit) {
      if (liveData.containsKey(key) && liveData[key]! >= limit) {
        alerts.add('$key: ${liveData[key]!.toStringAsFixed(1)}');
      }
    });
    if (alerts.isNotEmpty) {
      showAlert('High Sensor Readings', alerts.join(', '));
    }
  }

  void resetLiveData() {
    liveData["temp"] = 0.0; liveData["hum"] = 0.0; liveData["pressure"] = 1013.0;
    liveData["co2"] = 0.0; liveData["co"] = 0.0;
    liveData["pm1"] = 0.0; liveData["pm25"] = 0.0; liveData["pm10"] = 0.0;
  }

  currentRef.onValue.listen((event) {
    final data = event.snapshot.value as Map<dynamic, dynamic>?;
    if (data == null) return;

    // optional stale data check
    final lastSeen = data['lastSeen'];
    if (lastSeen is num) {
      final nowSec = DateTime.now().millisecondsSinceEpoch / 1000;
      if ((nowSec - lastSeen.toDouble()).abs() > 20) {
        resetLiveData();
        checkConnectivity(false);
        return;
      }
    }

    liveData["temp"] = (data['temperature'] ?? 0.0).toDouble();
    liveData["hum"] = (data['humidity'] ?? 0.0).toDouble();
    liveData["pressure"] = (data['pressure'] ?? 1013.0).toDouble();
    liveData["co2"] = (data['co2'] ?? 0.0).toDouble();
    liveData["co"] = (data['co'] ?? 0.0).toDouble();
    liveData["pm1"] = (data['pm1'] ?? 0.0).toDouble();
    liveData["pm25"] = (data['pm25'] ?? 0.0).toDouble();
    liveData["pm10"] = (data['pm10'] ?? 0.0).toDouble();

    offlineTimer?.cancel();
    offlineTimer = Timer(const Duration(seconds: 90), () {
      checkConnectivity(false);
      resetLiveData();
    });
    checkConnectivity(true);
    checkThresholds();
  });

  // Stop handler (triggered by the app’s Stop button or the notification action)
  service.on('stopService').listen((event) {
    _localNotifications.cancel(888);
    service.stopSelf();
  });
}