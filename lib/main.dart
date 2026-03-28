import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:intl/intl.dart';
import 'package:adhan/adhan.dart' as adhan;
import 'package:alarm/alarm.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:permission_handler/permission_handler.dart' hide ServiceStatus;
import 'package:hello_app/thasbeeh_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Alarm.init();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Imam',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
      ),
      home: const MyHomePage(title: 'Imam'),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key, required this.title});

  // This widget is the home page of your application. It is stateful, meaning
  // that it has a State object (defined below) that contains fields that affect
  // how it looks.

  // This class is the configuration for the state. It holds the values (in this
  // case the title) provided by the parent (in this case the App widget) and
  // used by the build method of the State. Fields in a Widget subclass are
  // always marked "final".

  final String title;

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class NextPrayerData {
  final String name;
  final DateTime time;
  final String remainingText;

  const NextPrayerData({
    required this.name,
    required this.time,
    required this.remainingText,
  });
}

class NextPrayerComparisonData {
  /// Adhan calculation with your local minute adjustments.
  final NextPrayerData adjusted;
  /// Plain Adhan (MWL + Shafi), no extra adjustments.
  final NextPrayerData standard;

  const NextPrayerComparisonData({
    required this.adjusted,
    required this.standard,
  });
}

class _MyHomePageState extends State<MyHomePage> {
  static const String _adhanAssetPath = 'assets/audio/adhan.mp3';

  static const String _lastLatKey = 'last_known_prayer_lat';
  static const String _lastLngKey = 'last_known_prayer_lng';
  static const String _backgroundAdhanEnabledKey = 'background_adhan_enabled';

  double? phoneHeading;
  double? targetBearing;
  late Future<NextPrayerComparisonData> _nextPrayerFuture;
  bool _usingPreviousLocation = false;
  bool _isLocationAvailable = false;
  bool _backgroundAdhanEnabled = true;
  StreamSubscription<ServiceStatus>? _locationServiceSubscription;
  StreamSubscription<dynamic>? _alarmRingingSubscription;
  bool _isAdhanDialogVisible = false;
  bool? _previousLocationServiceEnabled;

  double currentLat = 0;
  double currentLng = 0;

  double targetLat = 21.4225;
  double targetLng = 39.8262;

  Future<void> _updateLocationAvailability() async {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    final permission = await Geolocator.checkPermission();
    final permissionGranted = permission == LocationPermission.whileInUse ||
        permission == LocationPermission.always;

    if (!mounted) return;
    setState(() {
      _isLocationAvailable = serviceEnabled && permissionGranted;
    });
  }

  void _applyCoordinates(double lat, double lng) {
    if (!mounted) return;
    setState(() {
      currentLat = lat;
      currentLng = lng;
      targetBearing = calculateBearing(
        currentLat,
        currentLng,
        targetLat,
        targetLng,
      );
    });
  }

  Future<void> _saveLastLocation(double lat, double lng) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_lastLatKey, lat);
    await prefs.setDouble(_lastLngKey, lng);
  }

  Future<void> _loadBackgroundAdhanPreference() async {
    final prefs = await SharedPreferences.getInstance();
    final enabled = prefs.getBool(_backgroundAdhanEnabledKey) ?? true;
    if (!enabled) {
      await Alarm.stopAll();
    }
    if (!mounted) return;
    setState(() {
      _backgroundAdhanEnabled = enabled;
    });
  }

  Future<void> _setBackgroundAdhanEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_backgroundAdhanEnabledKey, enabled);
    if (!mounted) return;
    setState(() {
      _backgroundAdhanEnabled = enabled;
    });
    if (!enabled) {
      await Alarm.stopAll();
    } else {
      await _ensureAndroidPrayerPermissions();
      _refreshNextPrayer();
    }
  }

  Future<({double lat, double lng})?> _loadLastLocation() async {
    final prefs = await SharedPreferences.getInstance();
    final lat = prefs.getDouble(_lastLatKey);
    final lng = prefs.getDouble(_lastLngKey);
    if (lat == null || lng == null) {
      return null;
    }
    return (lat: lat, lng: lng);
  }

  Future<({double lat, double lng, bool usedPrevious})> getLocation({
    bool preferFreshLocation = false,
  }) async {
    Future<({double lat, double lng, bool usedPrevious})?> tryPlatformLastKnown() async {
      try {
        final last = await Geolocator.getLastKnownPosition();
        if (last != null) {
          _applyCoordinates(last.latitude, last.longitude);
          await _saveLastLocation(last.latitude, last.longitude);
          return (lat: last.latitude, lng: last.longitude, usedPrevious: true);
        }
      } catch (_) {}
      return null;
    }

    Future<({double lat, double lng, bool usedPrevious})?> trySaved() async {
      final saved = await _loadLastLocation();
      if (saved != null) {
        _applyCoordinates(saved.lat, saved.lng);
        return (lat: saved.lat, lng: saved.lng, usedPrevious: true);
      }
      return null;
    }

    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      await _updateLocationAvailability();
      if (preferFreshLocation) {
        throw Exception('Location services are disabled');
      }
      final saved = await trySaved();
      if (saved != null) return saved;
      final platformLastKnown = await tryPlatformLastKnown();
      if (platformLastKnown != null) return platformLastKnown;
      throw Exception('Location services are disabled');
    }

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }

    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      await _updateLocationAvailability();
      if (preferFreshLocation) {
        throw Exception('Location permission denied');
      }
      final saved = await trySaved();
      if (saved != null) return saved;
      throw Exception('Location permission denied');
    }

    try {
      final position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
        timeLimit: const Duration(seconds: 18),
      );
      _applyCoordinates(position.latitude, position.longitude);
      await _saveLastLocation(position.latitude, position.longitude);
      await _updateLocationAvailability();
      return (
        lat: position.latitude,
        lng: position.longitude,
        usedPrevious: false,
      );
    } catch (_) {}

    try {
      final position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.medium,
        timeLimit: const Duration(seconds: 12),
      );
      _applyCoordinates(position.latitude, position.longitude);
      await _saveLastLocation(position.latitude, position.longitude);
      await _updateLocationAvailability();
      return (
        lat: position.latitude,
        lng: position.longitude,
        usedPrevious: false,
      );
    } catch (_) {}

    try {
      final position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.low,
        timeLimit: const Duration(seconds: 10),
      );
      _applyCoordinates(position.latitude, position.longitude);
      await _saveLastLocation(position.latitude, position.longitude);
      await _updateLocationAvailability();
      return (
        lat: position.latitude,
        lng: position.longitude,
        usedPrevious: false,
      );
    } catch (_) {}

    if (preferFreshLocation) {
      final lastAfterFail = await tryPlatformLastKnown();
      if (lastAfterFail != null) return lastAfterFail;
      throw Exception(
        'Could not get your current location yet. Please wait a moment and tap refresh again.',
      );
    }

    final cached = await tryPlatformLastKnown();
    if (cached != null) return cached;

    final saved = await trySaved();
    if (saved != null) return saved;

    throw Exception(
      'Could not get your location. Try moving outdoors or tap Retry.',
    );
  }

  void _refreshNextPrayer() {
    setState(() {
      _nextPrayerFuture = getNextPrayerTime(preferFreshLocation: true);
    });
  }

  String _prayerLoadErrorMessage(Object? error) {
    if (error is TimeoutException) {
      return 'Getting your location timed out. Check GPS or tap Retry.';
    }
    if (error is LocationServiceDisabledException) {
      return 'Location is turned off. Enable it in settings and tap Retry.';
    }
    final msg = error.toString();
    if (msg.contains('Location services are disabled')) {
      return 'Location services are disabled. Turn them on and tap Retry.';
    }
    if (msg.contains('permission denied')) {
      return 'Location permission is required. Grant it in settings and tap Retry.';
    }
    if (msg.contains('Could not get your location')) {
      return msg.replaceFirst('Exception: ', '');
    }
    if (msg.contains('Next prayer time unavailable')) {
      return 'Could not determine the next prayer. Tap Retry.';
    }
    return 'Unable to load prayer times. Tap Retry.';
  }

  /// MWL + Shafi, same as before; minute tweaks only in [_areaAdjustedAdhanParams].
  adhan.CalculationParameters _standardAdhanParams() {
    final p = adhan.CalculationMethod.muslim_world_league.getParameters();
    p.madhab = adhan.Madhab.shafi;
    return p;
  }

  /// Former local `PrayerAdjustments` values, applied on top of Adhan MWL + Shafi.
  adhan.CalculationParameters _areaAdjustedAdhanParams() {
    final p = adhan.CalculationMethod.muslim_world_league.getParameters();
    p.madhab = adhan.Madhab.shafi;
    p.adjustments = adhan.PrayerAdjustments(
      fajr: -5,
      dhuhr: 3,
      asr: 4,
      maghrib: 5,
      isha: 8,
    );
    return p;
  }

  NextPrayerData getNextPrayerFromAdhanParams(
    double lat,
    double lon,
    adhan.CalculationParameters params,
  ) {
    final now = DateTime.now();
    final prayerTimes = adhan.PrayerTimes(
      adhan.Coordinates(lat, lon),
      adhan.DateComponents.from(now),
      params,
    );

    final schedule = <(String, DateTime)>[
      ('fajr', prayerTimes.fajr),
      ('dhuhr', prayerTimes.dhuhr),
      ('asr', prayerTimes.asr),
      ('maghrib', prayerTimes.maghrib),
      ('isha', prayerTimes.isha),
    ];

    for (final item in schedule) {
      if (!now.isAfter(item.$2)) {
        final remaining = item.$2.difference(now);
        return NextPrayerData(
          name: item.$1,
          time: item.$2,
          remainingText: formatRemainingDuration(remaining),
        );
      }
    }

    final tomorrow = now.add(const Duration(days: 1));
    final tomorrowPrayerTimes = adhan.PrayerTimes(
      adhan.Coordinates(lat, lon),
      adhan.DateComponents.from(tomorrow),
      params,
    );

    final remaining = tomorrowPrayerTimes.fajr.difference(now);
    return NextPrayerData(
      name: 'fajr',
      time: tomorrowPrayerTimes.fajr,
      remainingText: formatRemainingDuration(remaining),
    );
  }

  /// Android cannot grant these silently (Play policy / OS security). This runs
  /// automatically so the user only taps system "Allow" dialogs—not hunt in Settings.
  /// OEM extras (Xiaomi autostart, etc.) still have no public API.
  Future<void> _ensureAndroidPrayerPermissions() async {
    if (defaultTargetPlatform != TargetPlatform.android || kIsWeb) return;

    Future<void> gap() =>
        Future<void>.delayed(const Duration(milliseconds: 450));

    try {
      await Permission.locationWhenInUse.request();
      await gap();

      await Permission.notification.request();
      await gap();

      await Permission.scheduleExactAlarm.request();
      await gap();

      await Permission.ignoreBatteryOptimizations.request();
    } catch (_) {}
  }

  List<(String, DateTime)> _prayerScheduleFromAdhan(adhan.PrayerTimes pt) {
    return <(String, DateTime)>[
      ('Fajr', pt.fajr),
      ('Dhuhr', pt.dhuhr),
      ('Asr', pt.asr),
      ('Maghrib', pt.maghrib),
      ('Isha', pt.isha),
    ];
  }

  int _alarmIdForPrayer(DateTime date, int index) {
    return (date.year * 10000 + date.month * 100 + date.day) * 10 + index + 1;
  }

  Future<void> _syncBackgroundAdhanAlarms(double lat, double lon) async {
    if (!_backgroundAdhanEnabled) return;

    final now = DateTime.now();
    final today = adhan.PrayerTimes(
      adhan.Coordinates(lat, lon),
      adhan.DateComponents.from(now),
      _areaAdjustedAdhanParams(),
    );
    final tomorrowDate = now.add(const Duration(days: 1));
    final tomorrow = adhan.PrayerTimes(
      adhan.Coordinates(lat, lon),
      adhan.DateComponents.from(tomorrowDate),
      _areaAdjustedAdhanParams(),
    );

    final existing = await Alarm.getAlarms();
    for (final alarm in existing) {
      if (!await Alarm.isRinging(alarm.id)) {
        await Alarm.stop(alarm.id);
      }
    }

    final schedule = <(String, DateTime)>[
      ..._prayerScheduleFromAdhan(today),
      ..._prayerScheduleFromAdhan(tomorrow),
    ];

    for (var i = 0; i < schedule.length; i++) {
      final item = schedule[i];
      if (!item.$2.isAfter(now)) continue;

      final alarmSettings = AlarmSettings(
        id: _alarmIdForPrayer(item.$2, i),
        dateTime: item.$2,
        assetAudioPath: _adhanAssetPath,
        loopAudio: false,
        vibrate: true,
        warningNotificationOnKill: false,
        androidFullScreenIntent: true,
        // Avoid tying alarm audio to the Flutter task; improves behavior when the app is backgrounded.
        androidStopAlarmOnTermination: false,
        volumeSettings: VolumeSettings.fade(
          volume: 0.8,
          fadeDuration: const Duration(seconds: 3),
        ),
        notificationSettings: NotificationSettings(
          title: 'Adhan time',
          body: 'It is time for ${item.$1}',
          stopButton: 'Stop',
        ),
      );
      await Alarm.set(alarmSettings: alarmSettings);
    }
  }

  static const Duration _maxAdhanLateness = Duration(minutes: 3);

  void _setupAlarmRingingListener() {
    _alarmRingingSubscription = Alarm.ringing.listen((alarmSet) async {
      if (!mounted || _isAdhanDialogVisible) return;
      if (alarmSet.alarms.isEmpty) return;

      final now = DateTime.now();
      for (final alarm in alarmSet.alarms) {
        if (now.difference(alarm.dateTime) > _maxAdhanLateness) {
          await Alarm.stop(alarm.id);
          return;
        }
      }

      _isAdhanDialogVisible = true;
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) {
          return AlertDialog(
            title: const Text('Adhan is playing'),
            content: const Text('Tap stop to turn off Adhan.'),
            actions: [
              TextButton(
                onPressed: () async {
                  await Alarm.stopAll();
                  if (dialogContext.mounted) {
                    Navigator.of(dialogContext).pop();
                  }
                },
                child: const Text('Stop'),
              ),
            ],
          );
        },
      );
      _isAdhanDialogVisible = false;
    });
  }

  String formatTime(DateTime time) {
    return DateFormat('h.mm').format(time);
  }

  String formatRemainingDuration(Duration duration) {
    if (duration.isNegative) {
      return '0 minutes more';
    }

    final totalMinutes = duration.inMinutes;
    final hours = totalMinutes ~/ 60;
    final minutes = totalMinutes % 60;

    if (hours == 0) {
      return '$minutes minute${minutes == 1 ? '' : 's'} more';
    }

    if (minutes == 0) {
      return '$hours hour${hours == 1 ? '' : 's'} more';
    }

    return '$hours hour${hours == 1 ? '' : 's'} and $minutes minute${minutes == 1 ? '' : 's'} more';
  }

  Future<NextPrayerComparisonData> _bootstrapFirstLoad() async {
    await _ensureAndroidPrayerPermissions();
    return getNextPrayerTime();
  }

  Future<NextPrayerComparisonData> getNextPrayerTime({
    bool preferFreshLocation = false,
  }) async {
    final location = await getLocation(preferFreshLocation: preferFreshLocation);
    if (mounted) {
      setState(() {
        _usingPreviousLocation = location.usedPrevious;
      });
    }

    final data = NextPrayerComparisonData(
      adjusted: getNextPrayerFromAdhanParams(
        location.lat,
        location.lng,
        _areaAdjustedAdhanParams(),
      ),
      standard: getNextPrayerFromAdhanParams(
        location.lat,
        location.lng,
        _standardAdhanParams(),
      ),
    );

    // Do not block UI on alarm permission prompts or many Alarm.set calls.
    unawaited(
      _syncBackgroundAdhanAlarms(location.lat, location.lng).catchError((_) {}),
    );

    return data;
  }

  @override
  void initState() {
    super.initState();

    _loadBackgroundAdhanPreference();
    _setupAlarmRingingListener();
    _nextPrayerFuture = _bootstrapFirstLoad();
    _updateLocationAvailability();
    if (!kIsWeb) {
      Geolocator.isLocationServiceEnabled().then((enabled) {
        _previousLocationServiceEnabled = enabled;
      });
      _locationServiceSubscription =
          Geolocator.getServiceStatusStream().listen((status) async {
        await _updateLocationAvailability();
        final enabled = status == ServiceStatus.enabled;
        if (_previousLocationServiceEnabled == false &&
            enabled &&
            mounted) {
          _refreshNextPrayer();
        }
        _previousLocationServiceEnabled = enabled;
      });
    }

    FlutterCompass.events?.listen((event) {
      setState(() {
        phoneHeading = event.heading;
      });
    });
  }

  @override
  void dispose() {
    _locationServiceSubscription?.cancel();
    _alarmRingingSubscription?.cancel();
    super.dispose();
  }

  double calculateBearing(
    double lat1, double lon1, double lat2, double lon2) {

    var dLon = (lon2 - lon1) * pi / 180;

    lat1 = lat1 * pi / 180;
    lat2 = lat2 * pi / 180;

    var y = sin(dLon) * cos(lat2);
    var x = cos(lat1) * sin(lat2) -
        sin(lat1) * cos(lat2) * cos(dLon);

    var brng = atan2(y, x);

    brng = brng * 180 / pi;
    brng = (brng + 360) % 360;

    return brng;
  }

  @override
  Widget build(BuildContext context) {
    // This method is rerun every time setState is called, for instance as done
    // by the _incrementCounter method above.
    //
    // The Flutter framework has been optimized to make rerunning build methods
    // fast, so that you can just rebuild anything that needs updating rather
    // than having to individually change instances of widgets.
    return Scaffold(
      appBar: AppBar(
        // TRY THIS: Try changing the color here to a specific color (to
        // Colors.amber, perhaps?) and trigger a hot reload to see the AppBar
        // change color while the other colors stay the same.
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        toolbarHeight: 100,
        // Here we take the value from the MyHomePage object that was created by
        // the App.build method, and use it to set our appbar title.
        centerTitle: false,
        title: Padding(
          padding: const EdgeInsets.only(left: 8),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(40),
            child: Image.asset(
              'assets/icon/imam_logo.jpg',
              height: 80,
              width: 80,
              fit: BoxFit.cover,
            ),
          ),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 20),
            child: SizedBox(
              height: 28,
              child: ElevatedButton.icon(
                onPressed: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => const ThasbeehPage(),
                    ),
                  );
                },
                icon: const Icon(Icons.arrow_forward),
                label: const Text('Thasbeeh'),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 0),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(30),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      floatingActionButton: FloatingActionButton(
        onPressed: _refreshNextPrayer,
        backgroundColor: _isLocationAvailable ? Colors.green : Colors.red,
        tooltip: 'Refresh location',
        child: const Icon(Icons.my_location),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.start,
                  children: [
            const SizedBox(height: 25),
            const Text(
              'Direction of Namaz',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 26,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 16),
            // Compass Needle
            targetBearing == null
                ? const SizedBox(
                    height: 120,
                    child: Center(
                      child: Text(
                        'Direction unavailable',
                        style: TextStyle(color: Colors.black54),
                      ),
                    ),
                  )
                : Transform.rotate(
                    angle:
                        ((targetBearing! - (phoneHeading ?? 0)) * pi / 180),
                    child: const Icon(
                      Icons.navigation,
                      size: 120,
                      color: Colors.red,
                    ),
                  ),
            const SizedBox(height: 50),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 25),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  const Text('Play Adhan'),
                  const SizedBox(width: 10), // space between text and switch
                  Switch.adaptive(
                    value: _backgroundAdhanEnabled,
                    onChanged: _setBackgroundAdhanEnabled,
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 25),
              child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Flexible(
                      child: FutureBuilder<NextPrayerComparisonData>(
                    future: _nextPrayerFuture,
                    builder: (context, snapshot) {
                      if (snapshot.connectionState == ConnectionState.waiting) {
                        return const Align(
                          alignment: Alignment.centerLeft,
                          child: CircularProgressIndicator(),
                        );
                      } else if (snapshot.hasError) {
                        return Padding(
                          padding: const EdgeInsets.only(right: 12),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _prayerLoadErrorMessage(snapshot.error),
                                style: const TextStyle(
                                  fontSize: 14,
                                  color: Colors.black87,
                                ),
                              ),
                              const SizedBox(height: 8),
                              FilledButton.icon(
                                onPressed: _refreshNextPrayer,
                                icon: const Icon(Icons.refresh),
                                label: const Text('Retry'),
                              ),
                            ],
                          ),
                        );
                      } else {
                        final nextPrayer = snapshot.data!;
                        return Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (_usingPreviousLocation)
                              const Padding(
                                padding: EdgeInsets.only(bottom: 8),
                                child: Text(
                                  'Showing prayer time from your previous location',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.black54,
                                  ),
                                ),
                              ),
                            Column(
                              children: [
                                Container(
                                  width: MediaQuery.of(context).size.width * 0.7,
                                  height: 120,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 18,
                                    vertical: 16,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Colors.deepPurple.shade50,
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      const Text(
                                        "Next prayer (Masjid Time)",
                                        style: TextStyle(
                                          fontSize: 14,
                                          color: Colors.black54,
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        "${nextPrayer.adjusted.name} at ${formatTime(nextPrayer.adjusted.time)}",
                                        style: const TextStyle(
                                          fontSize: 22,
                                          fontWeight: FontWeight.bold,
                                          color: Colors.deepPurple,
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        nextPrayer.adjusted.remainingText,
                                        style: const TextStyle(
                                          fontSize: 16,
                                          fontWeight: FontWeight.w600,
                                          color: Colors.green,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Container(
                                  width: MediaQuery.of(context).size.width * 0.7,
                                  height: 120,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 18,
                                    vertical: 16,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Colors.deepPurple.shade50,
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      const Text(
                                        "Next prayer (standard Adhan)",
                                        style: TextStyle(
                                          fontSize: 14,
                                          color: Colors.black54,
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        "${nextPrayer.standard.name} at ${formatTime(nextPrayer.standard.time)}",
                                        style: const TextStyle(
                                          fontSize: 22,
                                          fontWeight: FontWeight.bold,
                                          color: Colors.deepPurple,
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        nextPrayer.standard.remainingText,
                                        style: const TextStyle(
                                          fontSize: 16,
                                          fontWeight: FontWeight.w600,
                                          color: Colors.green,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ],
                        );
                      }
                    },
                      ),
                    ),
                  ],
                ),
            ),

                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
