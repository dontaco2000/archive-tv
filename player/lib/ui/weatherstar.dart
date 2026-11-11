import 'dart:async';

import 'package:flutter/material.dart';

import '../weather/weather.dart';

const _font = 'Consolas';
const _yellow = Color(0xFFFFE34D);
const _shadow = [Shadow(color: Colors.black, offset: Offset(2, 2))];
const _days = ['MON', 'TUE', 'WED', 'THU', 'FRI', 'SAT', 'SUN'];
const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

TextStyle _text(double size, [Color color = Colors.white]) =>
    TextStyle(fontFamily: _font, fontSize: size, color: color, fontWeight: FontWeight.bold, shadows: _shadow, height: 1.15);

IconData _icon(int code) => switch (code) {
      0 || 1 => Icons.wb_sunny,
      2 => Icons.cloud_queue,
      3 => Icons.cloud,
      45 || 48 => Icons.dehaze,
      51 || 53 || 55 || 56 || 57 => Icons.grain,
      71 || 73 || 75 || 77 || 85 || 86 => Icons.ac_unit,
      95 || 96 || 99 => Icons.thunderstorm,
      _ => Icons.water_drop,
    };

Color _iconColor(int code) => code <= 1 ? const Color(0xFFFFC21A) : Colors.white;

/// Retro "Local on the 8s" style weather screens (WeatherStar 4000 look), drawn natively
/// at 640x480 and scaled into the 4:3 frame. Pages cycle every [pageTime]; data reloads every 15 min.
class WeatherStarScreen extends StatefulWidget {
  static const pageTime = Duration(seconds: 10);
  final Future<WeatherReport> Function() load;
  const WeatherStarScreen({super.key, required this.load});

  @override
  State<WeatherStarScreen> createState() => _WeatherStarScreenState();
}

class _WeatherStarScreenState extends State<WeatherStarScreen> {
  WeatherReport? _report;
  bool _failed = false;
  int _ticks = 0;
  Timer? _tick, _reload;

  @override
  void initState() {
    super.initState();
    _fetch();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => setState(() => _ticks++));
  }

  Future<void> _fetch() async {
    _reload?.cancel();
    try {
      final r = await widget.load();
      if (!mounted) return;
      setState(() {
        _report = r;
        _failed = false;
      });
      _reload = Timer(const Duration(minutes: 15), _fetch);
    } on Object {
      if (!mounted) return;
      setState(() => _failed = _report == null); // keep showing old data if we have some
      _reload = Timer(const Duration(minutes: 1), _fetch);
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    _reload?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final r = _report;
    final page = (_ticks ~/ WeatherStarScreen.pageTime.inSeconds) % 3;
    final (title, body) = r == null
        ? ('Local Weather', _message(_failed ? 'Weather unavailable.\nTrying again shortly...' : 'Loading weather...'))
        : switch (page) {
            0 => ('Current Conditions', _current(r)),
            1 => ('Local Forecast', _local(r)),
            _ => ('Extended Forecast', _extended(r)),
          };
    return ColoredBox(
      color: Colors.black,
      child: FittedBox(
        fit: BoxFit.fill,
        child: SizedBox(
          width: 640,
          height: 480,
          child: DecoratedBox(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0xFF1A0F5C), Color(0xFF3B2A9E), Color(0xFF7A3F8F)],
              ),
            ),
            child: Column(children: [
              _header(title),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(36, 6, 36, 10),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Color(0xFF1B2C8C), Color(0xFF3550C8)],
                      ),
                      border: Border.all(color: const Color(0xFF8FA2FF), width: 3),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Padding(padding: const EdgeInsets.all(18), child: body),
                  ),
                ),
              ),
              _footer(r),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _header(String title) {
    final now = DateTime.now();
    final h = now.hour % 12 == 0 ? 12 : now.hour % 12;
    final time = '$h:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')} ${now.hour < 12 ? 'AM' : 'PM'}';
    return Container(
      height: 86,
      padding: const EdgeInsets.fromLTRB(36, 14, 36, 4),
      decoration: const BoxDecoration(
        gradient: LinearGradient(colors: [Color(0xFFC0501A), Color(0xFF3B2A9E)], stops: [0.0, 0.45]),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
        Text('CUMULUS', style: _text(20, Colors.white).copyWith(letterSpacing: 2)),
        const SizedBox(width: 24),
        Expanded(child: Text(title, style: _text(30, _yellow), maxLines: 1, overflow: TextOverflow.fade, softWrap: false)),
        Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text(time, style: _text(16)),
          Text('${_days[now.weekday - 1]} ${_months[now.month - 1]} ${now.day}', style: _text(16)),
        ]),
      ]),
    );
  }

  Widget _footer(WeatherReport? r) => Container(
        height: 44,
        color: const Color(0xFF102070),
        padding: const EdgeInsets.symmetric(horizontal: 36),
        alignment: Alignment.centerLeft,
        child: Text(r == null ? 'Local weather' : 'Local weather for ${r.place}',
            style: _text(18), maxLines: 1, overflow: TextOverflow.ellipsis),
      );

  Widget _message(String text) => Center(child: Text(text, textAlign: TextAlign.center, style: _text(26)));

  Widget _current(WeatherReport r) {
    Widget row(String label, String value) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(children: [
            Expanded(child: Text(label, style: _text(20))),
            Text(value, style: _text(20, _yellow)),
          ]),
        );
    return Row(children: [
      Expanded(
        flex: 5,
        child: FittedBox(fit: BoxFit.scaleDown, child: Column(children: [
          Text('${r.tempF.round()}°', style: _text(84)),
          Text(r.condition, style: _text(24, _yellow), textAlign: TextAlign.center),
          const SizedBox(height: 8),
          Icon(_icon(r.code), size: 72, color: _iconColor(r.code), shadows: _shadow),
        ])),
      ),
      Expanded(
        flex: 6,
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          row('Humidity:', '${r.humidity}%'),
          row('Dewpoint:', '${r.dewF.round()}°'),
          row('Feels Like:', '${r.feelsF.round()}°'),
          row('Visibility:', '${r.visibilityMi.round()} mi.'),
          row('Pressure:', r.pressureInHg.toStringAsFixed(2)),
          row('Wind:', r.wind == 'Calm' ? 'Calm' : '${r.wind} mph'),
        ]),
      ),
    ]);
  }

  String _dayName(DateTime d, int i) => i == 0 ? 'TODAY' : (i == 1 ? 'TOMORROW' : _dayLong(d));

  String _dayLong(DateTime d) =>
      const ['MONDAY', 'TUESDAY', 'WEDNESDAY', 'THURSDAY', 'FRIDAY', 'SATURDAY', 'SUNDAY'][d.weekday - 1];

  Widget _local(WeatherReport r) {
    final lines = [
      for (final (i, d) in r.days.take(3).indexed)
        '${_dayName(d.date, i)}...${d.condition}. High ${d.hiF.round()}, low ${d.loF.round()}.'
            '${(d.rainChance ?? 0) >= 20 ? ' Chance of rain ${d.rainChance} percent.' : ''}',
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (final l in lines)
          Expanded(child: Align(alignment: Alignment.centerLeft, child: Text(l, style: _text(21), maxLines: 3, overflow: TextOverflow.ellipsis))),
      ],
    );
  }

  Widget _extended(WeatherReport r) {
    final days = r.days.skip(1).take(3).toList();
    return Row(children: [
      for (final d in days)
        Expanded(
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Text(_days[d.date.weekday - 1], style: _text(24, _yellow)),
            const SizedBox(height: 8),
            Icon(_icon(d.code), size: 64, color: _iconColor(d.code), shadows: _shadow),
            const SizedBox(height: 8),
            Text(d.condition, style: _text(18), textAlign: TextAlign.center, maxLines: 2),
            const SizedBox(height: 10),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Row(children: [
                Text('Lo ', style: _text(16, const Color(0xFF9EC8FF))),
                Text('${d.loF.round()}', style: _text(26)),
                const SizedBox(width: 12),
                Text('Hi ', style: _text(16, _yellow)),
                Text('${d.hiF.round()}', style: _text(26)),
              ]),
            ),
          ]),
        ),
    ]);
  }
}
