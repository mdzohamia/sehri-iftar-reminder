import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:adhan/adhan.dart';
import 'package:intl/intl.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  FlutterForegroundTask.initCommunicationPort();
  runApp(const SehriIftarApp());
}

@pragma('vm:entry-point')
void startCallback() {
  FlutterForegroundTask.setTaskHandler(AlarmTaskHandler());
}

class AlarmTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {
    FlutterForegroundTask.sendDataToMain({'tick': timestamp.toIso8601String()});
  }

  @override
  Future<void> onDestroy(DateTime timestamp) async {}
}

class SehriIftarApp extends StatelessWidget {
  const SehriIftarApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(scaffoldBackgroundColor: const Color(0xFF0D1527)),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
bool isMasterEnabled = false;
bool isSehriEnabled = true;
bool isIftarEnabled = true;
bool isOneMinTestActive = false;
bool _isPlayingAudio = false;

String sehriTimeStr = "লোডিং...";
String iftarTimeStr = "লোডিং...";
String statusMessage = "লোকেশন ট্র্যাক করা হচ্ছে...";
String selectedStartTime = "৩০ মিনিট আগে";
String selectedInterval = "৫ মিনিট পর পর";

final List<String> startTimes = ["৩ ঘণ্টা আগে", "২ ঘণ্টা আগে", "১ ঘণ্টা আগে", "৩০ মিনিট আগে"];
final List<String> intervals = ["৫ মিনিট পর পর", "১০ মিনিট পর পর", "২০ মিনিট পর পর", "৩০ মিনিট পর পর"];

final AudioPlayer _player = AudioPlayer();

Timer? _fallbackTimer;
DateTime? _nextSehriTime;
DateTime? _todayIftarTime;
DateTime? _oneMinTestTarget;
String _lastTriggeredMinute = "";
String _lastCalculatedDay = "";

@override
void initState() {
super.initState();
_initForegroundService();
FlutterForegroundTask.addTaskDataCallback(_onReceiveTaskData);
_loadData();
_checkForAppUpdate();

_fallbackTimer = Timer.periodic(const Duration(seconds: 5), (_) {
_checkAlarmLogic();
});
}

void _initForegroundService() {
FlutterForegroundTask.init(
androidNotificationOptions: AndroidNotificationOptions(
channelId: 'sehri_iftar_alarm_v2',
channelName: 'সেহরি ও ইফতার অ্যালার্ম',
channelImportance: NotificationChannelImportance.HIGH,
priority: NotificationPriority.HIGH,
),
iosNotificationOptions: const IOSNotificationOptions(showNotification: true, playSound: false),
foregroundTaskOptions: ForegroundTaskOptions(
eventAction: ForegroundTaskEventAction.repeat(10000),
autoRunOnBoot: true,
allowWakeLock: true,
allowWifiLock: true,
),
);
}

void _onReceiveTaskData(Object data) {
_checkAlarmLogic();
}

Future<void> _checkForAppUpdate() async {
try {
  const String versionUrl = "https://raw.githubusercontent.com/mdzohamia/sehri-iftar-reminder/main/version.json";

  final response = await http.get(Uri.parse(versionUrl));

if (response.statusCode == 200) {
final data = jsonDecode(response.body);
int latestVersion = data['latest_version'] ?? 1;
String versionName = data['version_name'] ?? "1.0.1";
String apkUrl = data['apk_url'] ?? "";
String notes = data['release_notes'] ?? "নতুন আপডেট পাওয়া গেছে।";

PackageInfo packageInfo = await PackageInfo.fromPlatform();
int currentVersionCode = int.tryParse(packageInfo.buildNumber) ?? 1;

if (latestVersion > currentVersionCode && mounted) {
showDialog(
context: context,
barrierDismissible: false,
builder: (ctx) => AlertDialog(
backgroundColor: const Color(0xFF16223F),
title: Text("নতুন আপডেট এসেছে! (v$versionName)", style: const TextStyle(color: Colors.orange, fontWeight: FontWeight.bold)),
content: Text(notes, style: const TextStyle(color: Colors.white70)),
actions: [
TextButton(
onPressed: () => Navigator.pop(ctx),
child: const Text("পরে করব", style: TextStyle(color: Colors.grey)),
),
ElevatedButton(
style: ElevatedButton.styleFrom(backgroundColor: Colors.teal),
onPressed: () async {
final Uri url = Uri.parse(apkUrl);
if (await canLaunchUrl(url)) {
await launchUrl(url, mode: LaunchMode.externalApplication);
}
},
child: const Text("আপডেট করুন", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
),
],
),
);
}
}
} catch (_) {}
}

Future<void> _loadData() async {
final prefs = await SharedPreferences.getInstance();
setState(() {
isMasterEnabled = prefs.getBool('isMasterEnabled') ?? false;
isSehriEnabled = prefs.getBool('isSehriEnabled') ?? true;
isIftarEnabled = prefs.getBool('isIftarEnabled') ?? true;
selectedStartTime = prefs.getString('selectedStartTime') ?? "৩০ মিনিট আগে";
selectedInterval = prefs.getString('selectedInterval') ?? "৫ মিনিট পর পর";
});
await _updateLocation();
}

Future<void> _saveData() async {
final prefs = await SharedPreferences.getInstance();
await prefs.setBool('isMasterEnabled', isMasterEnabled);
await prefs.setBool('isSehriEnabled', isSehriEnabled);
await prefs.setBool('isIftarEnabled', isIftarEnabled);
await prefs.setString('selectedStartTime', selectedStartTime);
await prefs.setString('selectedInterval', selectedInterval);
}

Future<void> _updateLocation() async {
final prefs = await SharedPreferences.getInstance();
double? savedLat = prefs.getDouble('lat');
double? savedLng = prefs.getDouble('lng');
if (savedLat != null && savedLng != null) {
_recalculatePrayerTimes(savedLat, savedLng, updateUI: true);
}

if (!await Geolocator.isLocationServiceEnabled()) {
if (savedLat == null) setState(() => statusMessage = "জিপিএস (GPS) বন্ধ আছে");
return;
}
LocationPermission perm = await Geolocator.checkPermission();
if (perm == LocationPermission.denied) {
perm = await Geolocator.requestPermission();
if (perm == LocationPermission.denied) {
if (savedLat == null) setState(() => statusMessage = "লোকেশন পারমিশন দেওয়া হয়নি");
return;
}
}

try {
Position pos = await Geolocator.getCurrentPosition(
locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
);
await prefs.setDouble('lat', pos.latitude);
await prefs.setDouble('lng', pos.longitude);
_recalculatePrayerTimes(pos.latitude, pos.longitude, updateUI: true);
} catch (_) {}
}

void _recalculatePrayerTimes(double lat, double lng, {bool updateUI = false}) {
final coords = Coordinates(lat, lng);
final params = CalculationMethod.karachi.getParameters()..madhab = Madhab.hanafi;
final now = DateTime.now();
final today = PrayerTimes.today(coords, params);

DateTime sTime = today.fajr.toLocal();
if (now.isAfter(sTime.add(const Duration(minutes: 1)))) {
sTime = PrayerTimes(coords, DateComponents.from(now.add(const Duration(days: 1))), params).fajr.toLocal();
}

DateTime iTime = today.maghrib.toLocal();
if (now.isAfter(iTime.add(const Duration(minutes: 1)))) {
iTime = PrayerTimes(coords, DateComponents.from(now.add(const Duration(days: 1))), params).maghrib.toLocal();
}

_nextSehriTime = sTime;
_todayIftarTime = iTime;
_lastCalculatedDay = "${now.year}-${now.month}-${now.day}";

if (updateUI && mounted) {
setState(() {
sehriTimeStr = DateFormat('hh:mm a').format(sTime);
iftarTimeStr = DateFormat('hh:mm a').format(iTime);
statusMessage = "লোকেশন ট্র্যাকড: সফল";
});
}
}

Future<void> _checkAlarmLogic() async {
if (_isPlayingAudio) return;

final now = DateTime.now();
String currentDayKey = "${now.year}-${now.month}-${now.day}";
String currentMinKey = "$currentDayKey-${now.hour}:${now.minute}";

// ১ মিনিট পরের লাইভ জিপিএস টেস্ট অ্যালার্ম চেক
if (isOneMinTestActive && _oneMinTestTarget != null) {
if (now.hour == _oneMinTestTarget!.hour && now.minute == _oneMinTestTarget!.minute && _lastTriggeredMinute != currentMinKey) {
_lastTriggeredMinute = currentMinKey;
if (mounted) setState(() => isOneMinTestActive = false);

DateTime nowMin = DateTime(now.year, now.month, now.day, now.hour, now.minute);
DateTime realTarget = _nextSehriTime ?? _todayIftarTime ?? nowMin.add(const Duration(minutes: 10));
DateTime targetMin = DateTime(realTarget.year, realTarget.month, realTarget.day, realTarget.hour, realTarget.minute);
int realDiff = targetMin.difference(nowMin).inMinutes;
if (realDiff <= 0) realDiff = 10;

await _playCleanPlaylist(_buildPlaylist('sehri', targetMin, nowMin, realDiff));
return;
}
}

if (!isMasterEnabled) return;

// রাত ১২টার পর নতুন দিন শুরু হলে বা সময় লোড না থাকলে সময় আপডেট করা
if (_nextSehriTime == null || _todayIftarTime == null || _lastCalculatedDay != currentDayKey) {
final prefs = await SharedPreferences.getInstance();
double? lat = prefs.getDouble('lat');
double? lng = prefs.getDouble('lng');
if (lat != null && lng != null) {
_recalculatePrayerTimes(lat, lng, updateUI: true);
}
}

if (_nextSehriTime == null || _todayIftarTime == null) return;
if (_lastTriggeredMinute == currentMinKey) return;

DateTime nowMinute = DateTime(now.year, now.month, now.day, now.hour, now.minute);
DateTime sehriMinute = DateTime(_nextSehriTime!.year, _nextSehriTime!.month, _nextSehriTime!.day, _nextSehriTime!.hour, _nextSehriTime!.minute);
DateTime iftarMinute = DateTime(_todayIftarTime!.year, _todayIftarTime!.month, _todayIftarTime!.day, _todayIftarTime!.hour, _todayIftarTime!.minute);

int diffS = sehriMinute.difference(nowMinute).inMinutes;
int diffI = iftarMinute.difference(nowMinute).inMinutes;

int limit = selectedStartTime == "৩ ঘণ্টা আগে" ? 180 : selectedStartTime == "২ ঘণ্টা আগে" ? 120 : selectedStartTime == "১ ঘণ্টা আগে" ? 60 : 30;
int step = selectedInterval == "৫ মিনিট পর পর" ? 5 : selectedInterval == "১০ মিনিট পর পর" ? 10 : selectedInterval == "২০ মিনিট পর পর" ? 20 : 30;

if (isSehriEnabled && diffS >= 0 && diffS <= limit) {
if (diffS == 0) {
_lastTriggeredMinute = currentMinKey;
await _playCleanPlaylist(['audio/sehri_final_end.mp3']);
_recalculateAfterEvent();
} else if (diffS == 10 || diffS == 5 || diffS % step == 0) {
_lastTriggeredMinute = currentMinKey;
List<String> list = _buildPlaylist('sehri', sehriMinute, nowMinute, diffS);
if (diffS == 10) list.add('audio/sehri_10_min.mp3');
if (diffS == 5) list.add('audio/sehri_5_min.mp3');
await _playCleanPlaylist(list);
}
}

if (isIftarEnabled && (diffI == 10 || diffI == 5 || diffI == 0)) {
_lastTriggeredMinute = currentMinKey;
if (diffI == 0) {
await _playCleanPlaylist(['audio/iftar_final_start.mp3']);
_recalculateAfterEvent();
} else {
await _playCleanPlaylist(_buildPlaylist('iftar', iftarMinute, nowMinute, diffI));
}
}
}

Future<void> _recalculateAfterEvent() async {
await Future.delayed(const Duration(minutes: 2));
final prefs = await SharedPreferences.getInstance();
double? lat = prefs.getDouble('lat');
double? lng = prefs.getDouble('lng');
if (lat != null && lng != null) {
_recalculatePrayerTimes(lat, lng, updateUI: true);
}
}

List<String> _buildPlaylist(String type, DateTime target, DateTime now, int diff) {
List<String> p = <String>[];

p.add('audio/${type}_base_1.mp3');
p.add('audio/h${_h12(target.hour)}.mp3');
if (target.minute > 0) {
p.add('audio/beje.mp3');
p.add('audio/m${target.minute}.mp3');
p.add('audio/minute.mp3');
}

p.add('audio/${type}_base_2.mp3');
p.add('audio/h${_h12(now.hour)}.mp3');
if (now.minute > 0) {
p.add('audio/beje.mp3');
p.add('audio/m${now.minute}.mp3');
p.add('audio/minute.mp3');
}

p.add('audio/${type}_base_3.mp3');
int remH = diff ~/ 60;
int remM = diff % 60;
if (remH > 0) {
p.add('audio/m$remH.mp3');
p.add('audio/hour.mp3');
}
if (remM > 0) {
p.add('audio/m$remM.mp3');
p.add('audio/minute.mp3');
}
p.add('audio/${type}_base_4.mp3');

return p;
}

int _h12(int h) => (h % 12 == 0) ? 12 : (h % 12);

Future<void> _playCleanPlaylist(List<String> paths) async {
if (_isPlayingAudio) return;
_isPlayingAudio = true;

try {
await _player.stop();
await _player.setReleaseMode(ReleaseMode.stop);
await _player.setVolume(1.0);
await _player.setAudioContext(AudioContext(
android: const AudioContextAndroid(
isSpeakerphoneOn: true,
stayAwake: true,
contentType: AndroidContentType.speech,
usageType: AndroidUsageType.alarm,
audioFocus: AndroidAudioFocus.gainTransientMayDuck,
),
));

for (String path in paths) {
try {
Completer<void> done = Completer<void>();
StreamSubscription? sub;
sub = _player.onPlayerComplete.listen((_) {
if (!done.isCompleted) done.complete();
sub?.cancel();
});

await _player.play(AssetSource(path));
await done.future.timeout(const Duration(seconds: 15), onTimeout: () {
sub?.cancel();
});
} catch (_) {}
}
} finally {
_isPlayingAudio = false;
}
}

Future<void> _toggleMaster(bool val) async {
setState(() => isMasterEnabled = val);
await _saveData();
if (val) {
if (await FlutterForegroundTask.checkNotificationPermission() != NotificationPermission.granted) {
await FlutterForegroundTask.requestNotificationPermission();
}
if (!await FlutterForegroundTask.isIgnoringBatteryOptimizations) {
await FlutterForegroundTask.requestIgnoreBatteryOptimization();
}
if (await FlutterForegroundTask.isRunningService) {
await FlutterForegroundTask.restartService();
} else {
await FlutterForegroundTask.startService(
serviceId: 256,
notificationTitle: 'সেহরি ও ইফতার অ্যালার্ম চালু আছে',
notificationText: 'ফোন লক থাকলেও নির্ধারিত সময়ে অ্যালার্ম বাজবে',
callback: startCallback,
);
}
} else {
await FlutterForegroundTask.stopService();
}
}

void _scheduleOneMinuteTest() {
final nextMin = DateTime.now().add(const Duration(minutes: 1));
setState(() {
_oneMinTestTarget = nextMin;
isOneMinTestActive = true;
});
ScaffoldMessenger.of(context).showSnackBar(
SnackBar(
content: Text("ঠিক ${DateFormat('hh:mm a').format(nextMin)} মিনিটে সেহরির জিপিএস সময় অনুযায়ী অ্যালার্ম বাজবে!"),
backgroundColor: Colors.green,
duration: const Duration(seconds: 5),
),
);
}

@override
void dispose() {
_fallbackTimer?.cancel();
FlutterForegroundTask.removeTaskDataCallback(_onReceiveTaskData);
_player.dispose();
super.dispose();
}

@override
Widget build(BuildContext context) {
return Scaffold(
appBar: AppBar(
title: const Text("সেহরি ও ইফতার রিমাইন্ডার", style: TextStyle(color: Colors.orange, fontWeight: FontWeight.bold, fontSize: 18)),
backgroundColor: Colors.transparent,
elevation: 0,
centerTitle: true,
),
body: SingleChildScrollView(
padding: const EdgeInsets.all(16.0),
child: Column(
crossAxisAlignment: CrossAxisAlignment.stretch,
children: [
Card(
color: const Color(0xFF16223F),
shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
child: Padding(
padding: const EdgeInsets.all(20.0),
child: Row(
mainAxisAlignment: MainAxisAlignment.spaceAround,
children: [
Column(children: [
const Text("পরবর্তী সেহরির শেষ সময়", style: TextStyle(color: Colors.grey, fontSize: 13)),
const SizedBox(height: 8),
Text(sehriTimeStr, style: const TextStyle(color: Colors.cyanAccent, fontSize: 22, fontWeight: FontWeight.bold)),
]),
Container(width: 1, height: 50, color: Colors.grey.withAlpha(100)),
Column(children: [
const Text("পরবর্তী ইফতারের সময়", style: TextStyle(color: Colors.grey, fontSize: 13)),
const SizedBox(height: 8),
Text(iftarTimeStr, style: const TextStyle(color: Colors.orangeAccent, fontSize: 22, fontWeight: FontWeight.bold)),
]),
],
),
),
),
const SizedBox(height: 15),
ElevatedButton.icon(
onPressed: isOneMinTestActive ? null : _scheduleOneMinuteTest,
icon: const Icon(Icons.timer, color: Colors.white),
label: Text(
isOneMinTestActive ? "অপেক্ষা করুন... ১ মিনিট পর ভয়েস অ্যালার্ম বাজবে" : "⏱️ ১ মিনিট পরের অ্যালার্ম ও ভয়েস টেস্ট",
style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.white),
),
style: ElevatedButton.styleFrom(
backgroundColor: Colors.teal,
disabledBackgroundColor: Colors.teal.withAlpha(120),
padding: const EdgeInsets.symmetric(vertical: 14),
shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
),
),
const SizedBox(height: 15),
Card(
color: Colors.white,
shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
child: Padding(
padding: const EdgeInsets.all(16.0),
child: Column(
crossAxisAlignment: CrossAxisAlignment.start,
children: [
const Text("কত সময় আগে থেকে অ্যালার্ম শুনতে চান? (সেহরির জন্য)", style: TextStyle(color: Colors.black54, fontSize: 13, fontWeight: FontWeight.bold)),
DropdownButton<String>(
value: selectedStartTime,
isExpanded: true,
dropdownColor: Colors.white,
style: const TextStyle(color: Colors.black, fontSize: 16),
items: startTimes.map((String v) => DropdownMenuItem<String>(value: v, child: Text(v))).toList(),
onChanged: (v) { setState(() => selectedStartTime = v!); _saveData(); },
),
  const SizedBox(height: 15),
  const Text("কত মিনিট পর পর শুনতে চান? (সেহরির জন্য)", style: TextStyle(color: Colors.black54, fontSize: 13, fontWeight: FontWeight.bold)),
  DropdownButton<String>(
    value: selectedInterval,
    isExpanded: true,
    dropdownColor: Colors.white,
    style: const TextStyle(color: Colors.black, fontSize: 16),
    items: intervals.map((String v) => DropdownMenuItem<String>(value: v, child: Text(v))).toList(),
    onChanged: (v) { setState(() => selectedInterval = v!); _saveData(); },
  ),
],
),
),
),
  const SizedBox(height: 20),
  const Text("🔔 রিমাইন্ডার কন্ট্রোল প্যানেল", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.orange)),
  const SizedBox(height: 10),
  Card(
    color: const Color(0xFF16223F),
    child: SwitchListTile(
      title: const Text("মাস্টার সুইচ (সব অ্যালার্ম অন/অফ)", style: TextStyle(fontWeight: FontWeight.bold)),
      subtitle: Text(isMasterEnabled ? "ব্যাকগ্রাউন্ড ও লক-স্ক্রিন সার্ভিস চালু আছে" : "সার্ভিস সম্পূর্ণ বন্ধ", style: const TextStyle(fontSize: 12)),
      value: isMasterEnabled,
      activeTrackColor: Colors.green,
      onChanged: _toggleMaster,
    ),
  ),
  Card(
    color: const Color(0xFF16223F),
    child: SwitchListTile(
      title: const Text("সেহরি ভয়েস রিমাইন্ডার"),
      value: isSehriEnabled,
      activeTrackColor: Colors.cyan,
      onChanged: isMasterEnabled ? (v) { setState(() => isSehriEnabled = v); _saveData(); } : null,
    ),
  ),
  Card(
    color: const Color(0xFF16223F),
    child: SwitchListTile(
      title: const Text("ইফতার ভয়েস রিমাইন্ডার (১০ ও ৫ মিনিট আগে এবং ইফতারের সময়)"),
      value: isIftarEnabled,
      activeTrackColor: Colors.orangeAccent,
      onChanged: isMasterEnabled ? (v) { setState(() => isIftarEnabled = v); _saveData(); } : null,
    ),
  ),
  const SizedBox(height: 25),
  Row(
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      const Icon(Icons.gps_fixed, color: Colors.redAccent, size: 18),
      const SizedBox(width: 8),
      Text(statusMessage, style: const TextStyle(color: Colors.tealAccent, fontSize: 14, fontWeight: FontWeight.w500)),
    ],
  ),
],
),
),
);
}
}
