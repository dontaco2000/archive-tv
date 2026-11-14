import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../weather/weather.dart';

// The Cumulus weather channel drawn natively (no WebView), in the look of the Archive TV Server's weather
// channel (modules/guidechannel/lib/src/weather_renderer.dart): laid out on a 640x480 canvas with the
// server's coordinates and palette and scaled into the 4:3 frame.

const _navy = Color(0xFF101A5C);
const _navyDark = Color(0xFF0B1348);
const _line = Color(0xFF05092A);
const _cell = Color(0xFF1E2C8A);
const _now = Color(0xFF2E45C8);
const _bar = Color(0xFF080F3E);
const _yellow = Color(0xFFFFEB3B);
const _white = Colors.white;
const _pale = Color(0xFFB8C6FF);
const _red = Color(0xFFB71C1C);
const _orange = Color(0xFFFF9800);
const _blue = Color(0xFF4FC3F7);
const _cloud = Color(0xFFECEFF1);
const _darkCloud = Color(0xFF90A4AE);

const _days = ['MON', 'TUE', 'WED', 'THU', 'FRI', 'SAT', 'SUN'];
const _months = ['JAN', 'FEB', 'MAR', 'APR', 'MAY', 'JUN', 'JUL', 'AUG', 'SEP', 'OCT', 'NOV', 'DEC'];

const _topHeight = 126.0, _gridTop = 156.0, _bodyH = 480 - _gridTop;

// Arial on Windows (the server's font); Android falls back to its own sans.
TextStyle _ts(double size, Color c) => TextStyle(
  fontFamily: 'Arial',
  decoration: TextDecoration.none, // no Material ancestor needed
  fontSize: size,
  color: c,
  height: 1.1,
  shadows: const [Shadow(color: Color(0xFF000018), offset: Offset(1, 1))],
);
final _small = _ts(14, _white), _big = _ts(24, _white), _huge = _ts(48, _white);

Widget _text(String s, TextStyle st, Color c, {TextAlign align = TextAlign.left, int maxLines = 1}) => Text(
  s,
  style: st.copyWith(color: c),
  textAlign: align,
  maxLines: maxLines,
  softWrap: maxLines > 1,
  overflow: TextOverflow.ellipsis,
);

/// Text placed at (x, y), [w] wide (left/centre/right aligned inside that width).
Widget _at(double x, double y, double w, String s, TextStyle st, Color c, {TextAlign align = TextAlign.left, int maxLines = 1}) =>
    Positioned(
      left: x,
      top: y,
      width: w,
      child: _text(s, st, c, align: align, maxLines: maxLines),
    );

Widget _centered(double cx, double y, double w, String s, TextStyle st, Color c, {int maxLines = 1}) =>
    _at(cx - w / 2, y, w, s, st, c, align: TextAlign.center, maxLines: maxLines);

Widget _panel(double x0, double y0, double x1, double y1, [Color c = _cell]) => Positioned(
  left: x0,
  top: y0,
  width: x1 - x0,
  height: y1 - y0,
  child: ColoredBox(color: c),
);

String _clock(DateTime t) => '${t.hour % 12 == 0 ? 12 : t.hour % 12}:${t.minute.toString().padLeft(2, '0')}';
String _ampm(DateTime t) => t.hour < 12 ? 'AM' : 'PM';
String _deg(double v) => '${v.round()}°';

/// The screens, in order. [alerts] only when there are active alerts; [none] alone without data.
enum WeatherPage { alerts, current, hourly, today, extended, none }

List<WeatherPage> weatherPages(WeatherReport? w) => w == null
    ? const [WeatherPage.none]
    : [if (w.alerts.isNotEmpty) WeatherPage.alerts, WeatherPage.current, WeatherPage.hourly, WeatherPage.today, WeatherPage.extended];

const _tabs = {
  WeatherPage.alerts: 'ALERTS',
  WeatherPage.current: 'NOW',
  WeatherPage.hourly: 'HOURLY',
  WeatherPage.today: 'TODAY',
  WeatherPage.extended: 'EXTENDED',
  WeatherPage.none: 'WEATHER',
};

const _titles = {
  WeatherPage.alerts: 'WEATHER ALERTS',
  WeatherPage.current: 'CURRENT CONDITIONS',
  WeatherPage.hourly: 'HOURLY FORECAST',
  WeatherPage.today: "TODAY'S FORECAST",
  WeatherPage.extended: 'EXTENDED FORECAST',
  WeatherPage.none: 'LOCAL WEATHER',
};

/// The weather channel's picture: a header (wordmark, WEATHER, clock, a box with the place, the screen's
/// title and the update time, a date + tab strip) over screens that hold [hold] then slide left over [slide].
/// Data reloads every 15 min (1 min after a failure; old data stays up).
class CumulusWeatherScreen extends StatefulWidget {
  static const hold = Duration(seconds: 9), slide = Duration(seconds: 1);
  final Future<WeatherReport> Function() load;

  /// The place shown before any data arrived.
  final String place;
  final DateTime Function() clock;
  const CumulusWeatherScreen({super.key, required this.load, this.place = '', this.clock = DateTime.now});

  @override
  State<CumulusWeatherScreen> createState() => _CumulusWeatherScreenState();
}

class _CumulusWeatherScreenState extends State<CumulusWeatherScreen> with SingleTickerProviderStateMixin {
  WeatherReport? _report;
  bool _failed = false;
  int _page = 0;
  Timer? _hold, _reload;
  late final AnimationController _slide = AnimationController(vsync: this, duration: CumulusWeatherScreen.slide)
    ..addStatusListener((s) {
      if (s != AnimationStatus.completed) return;
      setState(() => _page++);
      _slide.value = 0;
      _schedule();
    });

  @override
  void initState() {
    super.initState();
    _fetch();
    _schedule();
  }

  // Hold, then one 1 s slide; the next hold starts when the slide ends. Nothing animates during the hold.
  void _schedule() => _hold = Timer(CumulusWeatherScreen.hold, () => _slide.forward(from: 0));

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
      setState(() => _failed = true);
      _reload = Timer(const Duration(minutes: 1), _fetch);
    }
  }

  @override
  void dispose() {
    _hold?.cancel();
    _reload?.cancel();
    _slide.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final w = _report, now = widget.clock();
    final pages = weatherPages(w);
    final page = pages[_page % pages.length], next = pages[(_page + 1) % pages.length];
    Widget body(WeatherPage p) => RepaintBoundary(
      child: SizedBox(
        width: 640,
        height: _bodyH,
        child: _Page(page: p, report: w, now: now, failed: _failed),
      ),
    );
    final a = body(page), b = body(next);
    return ColoredBox(
      color: Colors.black,
      child: FittedBox(
        fit: BoxFit.contain,
        child: SizedBox(
          width: 640,
          height: 480,
          child: Stack(
            children: [
              Positioned(
                left: 0,
                top: 0,
                width: 640,
                height: _gridTop,
                child: _Header(report: w, place: widget.place, page: page, pages: pages, now: now, clock: widget.clock),
              ),
              Positioned(
                left: 0,
                top: _gridTop,
                width: 640,
                height: _bodyH,
                child: ClipRect(
                  child: AnimatedBuilder(
                    animation: _slide,
                    builder: (_, _) {
                      final t = _slide.value, f = t * t * (3 - 2 * t); // smoothstep, as the server
                      return Stack(
                        children: [
                          Transform.translate(offset: Offset(-640 * f, 0), child: a),
                          if (f > 0) Transform.translate(offset: Offset(640 * (1 - f), 0), child: b),
                        ],
                      );
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final WeatherReport? report;
  final String place;
  final WeatherPage page;
  final List<WeatherPage> pages;
  final DateTime now;
  final DateTime Function() clock;
  const _Header({
    required this.report,
    required this.place,
    required this.page,
    required this.pages,
    required this.now,
    required this.clock,
  });

  @override
  Widget build(BuildContext context) {
    final w = report;
    String? updated;
    var old = false;
    if (w != null) {
      final age = now.difference(w.fetched);
      old = age > const Duration(hours: 1);
      final f = w.fetched;
      final when = '${old && age > const Duration(hours: 20) ? '${_months[f.month - 1]} ${f.day} ' : ''}${_clock(f)} ${_ampm(f)}';
      updated = old ? 'LAST UPDATED $when' : 'UPDATED $when';
    }
    const tx = 342.0, room = 632 - 8 - tx;
    return Stack(
      children: [
        const Positioned.fill(child: CustomPaint(painter: _Stripes())),
        Positioned(
          left: 8,
          top: 4,
          width: 208,
          height: 78,
          // 468x176 asset (2.25x the server's 208x78: 1080p sharp); decoded at that size, not more.
          child: Image.asset('assets/branding/wordmark.png', fit: BoxFit.contain, filterQuality: FilterQuality.medium),
        ),
        _at(14, 98, 90, 'WEATHER', _small, _yellow),
        Positioned(
          left: 0,
          top: 88,
          width: 216,
          child: RepaintBoundary(child: _Clock(clock: clock)),
        ),
        // title box: yellow edge, the Cumulus logo, place / screen / updated
        _panel(226, 6, 634, 120, _yellow),
        _panel(228, 8, 632, 118),
        _panel(234, 14, 334, 90, _navyDark),
        Positioned(
          left: 234,
          top: 16,
          width: 100,
          height: 72,
          // the 1024 px channel logo, decoded small (Fire Stick memory)
          child: Image.asset('assets/logos/cumulus.png', cacheWidth: 240, fit: BoxFit.contain, filterQuality: FilterQuality.medium),
        ),
        _at(tx, 12, room, (w?.place ?? place).toUpperCase(), _big, _white),
        _at(tx, 44, room, _titles[page]!, _big, _yellow),
        if (updated != null) _at(tx, 88, room, updated, _small, old ? _orange : _pale),
        // tab strip: the date, then one tab per screen (the shown one highlighted)
        _panel(0, _topHeight, 640, _gridTop, _bar),
        _panel(0, _topHeight, 640, _topHeight + 2, _yellow),
        _at(10, _topHeight + 8, 110, '${_days[now.weekday - 1]} ${_months[now.month - 1]} ${now.day}', _small, _yellow),
        Positioned(
          right: 8,
          top: _topHeight + 5,
          height: 22,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final p in pages)
                Container(
                  margin: const EdgeInsets.only(left: 4),
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  alignment: Alignment.center,
                  color: p == page ? (p == WeatherPage.alerts ? _red : _now) : null,
                  child: _text(_tabs[p]!, _small, p == page ? _yellow : _pale),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Navy band with dark stripes every other line (the guide's top band).
class _Stripes extends CustomPainter {
  const _Stripes();

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, _topHeight), Paint()..color = _navy);
    final p = Paint()..color = _navyDark;
    for (var y = 0.0; y < _topHeight; y += 2) {
      canvas.drawRect(Rect.fromLTWH(0, y, size.width, 1), p);
    }
  }

  @override
  bool shouldRepaint(_Stripes old) => false;
}

/// The ticking clock, right-aligned at x 216: "10:29:45" big white, "PM" small yellow. Only this repaints each second.
class _Clock extends StatefulWidget {
  final DateTime Function() clock;
  const _Clock({required this.clock});

  @override
  State<_Clock> createState() => _ClockState();
}

class _ClockState extends State<_Clock> {
  late final Timer _t;

  @override
  void initState() {
    super.initState();
    _t = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _t.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = widget.clock();
    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerRight,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          _text('${_clock(l)}:${l.second.toString().padLeft(2, '0')}', _big, _white),
          const SizedBox(width: 4),
          _text(_ampm(l), _small, _yellow),
        ],
      ),
    );
  }
}

class _Page extends StatelessWidget {
  final WeatherPage page;
  final WeatherReport? report;
  final DateTime now;
  final bool failed;
  const _Page({required this.page, required this.report, required this.now, required this.failed});

  @override
  Widget build(BuildContext context) {
    final w = report;
    return Stack(
      children: [
        const Positioned.fill(child: ColoredBox(color: _line)),
        ...switch (page) {
          WeatherPage.none => _none(),
          WeatherPage.alerts => _alerts(w!),
          WeatherPage.current => _current(w!),
          WeatherPage.hourly => _hourly(w!),
          WeatherPage.today => _today(w!),
          WeatherPage.extended => _extended(w!),
        },
      ],
    );
  }

  List<Widget> _none() => [
    _panel(10, 10, 630, 314),
    if (failed) ...[
      _centered(320, 120, 600, 'WEATHER DATA NOT AVAILABLE', _big, _yellow),
      _centered(320, 160, 600, 'Checking again in a few minutes.', _small, _white),
    ] else
      _centered(320, 130, 600, 'LOADING WEATHER...', _big, _yellow),
  ];

  List<Widget> _notAvailable(String s) => [_panel(10, 10, 630, 314), _centered(320, 150, 600, s, _big, _pale)];

  static String _condition(int code, bool day) => !day && code <= 1 ? (code == 0 ? 'Clear' : 'Mostly Clear') : wmoText(code);

  /// Label left, value right, in a panel row.
  List<Widget> _row(double x0, double x1, double y, String label, String value) => [
    _at(x0 + 12, y + 8, 150, label, _small, _pale),
    _at(x0 + 160, y + 2, x1 - x0 - 172, value, _big, _white, align: TextAlign.right),
  ];

  List<Widget> _rows(double y0, double step, List<(String, String)> rows) => [
    for (final (i, (label, value)) in rows.indexed) ...[
      ..._row(310, 630, y0 + i * step, label, value),
      if (i < rows.length - 1) _panel(322, y0 + i * step + step - 8, 618, y0 + i * step + step - 7, _line),
    ],
  ];

  List<Widget> _current(WeatherReport w) {
    final u = w.imperial;
    final vis = w.visibility < 10 ? w.visibility.toStringAsFixed(1) : '${w.visibility.round()}';
    return [
      _panel(10, 10, 300, 314),
      _icon(w.code, 155, 86, 64, day: w.isDay),
      _centered(155, 150, 280, _deg(w.temp), _huge, _white),
      _centered(155, 214, 270, _condition(w.code, w.isDay), _big, _yellow),
      _centered(155, 256, 270, 'FEELS LIKE ${_deg(w.feels)}', _small, _pale),
      _panel(310, 10, 630, 314),
      ..._rows(18, 48, [
        ('HUMIDITY', '${w.humidity}%'),
        ('DEW POINT', _deg(w.dew)),
        ('WIND', w.windSpeed.round() == 0 ? 'Calm' : '${w.wind} ${w.speedUnit}'),
        if (w.gusts != null && w.gusts!.round() > w.windSpeed.round() + 4) ('GUSTS', '${w.gusts!.round()} ${w.speedUnit}'),
        ('PRESSURE', u ? '${w.pressure.toStringAsFixed(2)} in' : '${w.pressure.round()} hPa'),
        ('VISIBILITY', '$vis ${u ? 'mi' : 'km'}'),
      ]),
    ];
  }

  List<Widget> _hourly(WeatherReport w) {
    final from = DateTime(now.year, now.month, now.day, now.hour);
    final hours = w.hours.where((h) => !h.time.isBefore(from)).take(8).toList();
    return [
      _panel(10, 6, 630, 30),
      _at(22, 11, 100, 'TIME', _small, _yellow),
      _at(150, 11, 80, 'TEMP', _small, _yellow),
      _at(236, 11, 200, 'CONDITIONS', _small, _yellow),
      _at(552, 11, 70, 'RAIN', _small, _yellow),
      if (hours.isEmpty) ...[
        _panel(10, 34, 630, 314),
        _centered(320, 150, 600, 'Hourly forecast not available', _big, _pale),
      ] else
        for (final (i, h) in hours.indexed) ...[
          _panel(10, 34 + i * 35.0, 630, 34 + i * 35.0 + 33),
          _at(
            22,
            34 + i * 35.0 + 4,
            125,
            '${h.time.hour % 12 == 0 ? 12 : h.time.hour % 12} ${_ampm(h.time)}',
            _big,
            i == 0 ? _yellow : _white,
          ),
          _at(150, 34 + i * 35.0 + 4, 60, _deg(h.temp), _big, _white),
          _icon(h.code, 214, 34 + i * 35.0 + 16, 22, day: h.time.hour >= 6 && h.time.hour < 19),
          _at(236, 34 + i * 35.0 + 4, 300, _condition(h.code, h.time.hour >= 6 && h.time.hour < 19), _big, _white),
          if (h.rainChance != null) _at(552, 34 + i * 35.0 + 4, 76, '${h.rainChance}%', _big, h.rainChance! >= 50 ? _blue : _pale),
        ],
    ];
  }

  DayForecast? _dayOf(WeatherReport w) {
    for (final d in w.days) {
      if (d.date.year == now.year && d.date.month == now.month && d.date.day == now.day) return d;
    }
    return w.days.firstOrNull;
  }

  List<Widget> _today(WeatherReport w) {
    final d = _dayOf(w);
    if (d == null) return _notAvailable("Today's forecast not available");
    String t(DateTime? x) => x == null ? '--' : '${_clock(x)} ${_ampm(x)}';
    return [
      _panel(10, 10, 300, 314),
      _icon(d.code, 155, 86, 64),
      _centered(155, 150, 270, d.condition, _big, _yellow),
      Positioned(
        left: 10,
        top: 186,
        width: 290,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [_text('HIGH ', _small, _pale), _text(_deg(d.hi), _huge, _white)],
        ),
      ),
      Positioned(
        left: 10,
        top: 254,
        width: 290,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [_text('LOW ', _small, _pale), _text(_deg(d.lo), _big, _pale)],
        ),
      ),
      _panel(310, 10, 630, 314),
      ..._rows(22, 56, [
        ('CHANCE OF RAIN', d.rainChance == null ? '--' : '${d.rainChance}%'),
        ('SUNRISE', t(d.sunrise)),
        ('SUNSET', t(d.sunset)),
        ('UV INDEX', d.uvMax == null ? '--' : '${d.uvMax!.round()}'),
        ('WIND UP TO', d.windMax == null ? '--' : '${d.windMax!.round()} ${w.speedUnit}'),
      ]),
    ];
  }

  List<Widget> _extended(WeatherReport w) {
    final noon = DateTime(now.year, now.month, now.day, 12);
    final days = w.days.where((d) => d.date.isAfter(noon)).take(6).toList();
    if (days.isEmpty) return _notAvailable('Extended forecast not available');
    final cw = (620 / days.length).floorToDouble();
    return [for (final (i, d) in days.indexed) ..._dayColumn(10 + i * cw, cw, d)];
  }

  List<Widget> _dayColumn(double x0, double cw, DayForecast d) {
    final x1 = x0 + cw - 4, cx = (x0 + x1) / 2, pw = x1 - x0 - 8;
    return [
      _panel(x0, 10, x1, 314),
      _centered(cx, 16, pw, _days[d.date.weekday - 1], _big, _yellow),
      _centered(cx, 46, pw, '${_months[d.date.month - 1]} ${d.date.day}', _small, _pale),
      _icon(d.code, cx, 100, 34),
      _centered(cx, 146, pw, d.condition, _small, _white, maxLines: 2),
      _at(cx - 20, 190, 40, 'HI', _small, _pale),
      _at(cx - 20, 204, pw, _deg(d.hi), _big, _white),
      _at(cx - 20, 236, 40, 'LO', _small, _pale),
      _at(cx - 20, 250, pw, _deg(d.lo), _big, _pale),
      if (d.rainChance != null) _centered(cx, 290, pw, 'RAIN ${d.rainChance}%', _small, d.rainChance! >= 50 ? _blue : _pale),
    ];
  }

  List<Widget> _alerts(WeatherReport w) {
    const fits = 3; // event bar + up to 3 headline lines each: three fill the panel
    final shown = w.alerts.take(fits).toList(), more = w.alerts.length - shown.length;
    return [
      _panel(10, 10, 630, 314),
      Positioned(
        left: 18,
        top: 18,
        width: 604,
        height: more > 0 ? 270 : 290,
        child: ClipRect(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final a in shown) ...[
                Container(
                  height: 30,
                  color: _red,
                  padding: const EdgeInsets.only(left: 6),
                  alignment: Alignment.centerLeft,
                  child: _text(a.event.toUpperCase(), _big, _white),
                ),
                Padding(padding: const EdgeInsets.fromLTRB(6, 4, 6, 10), child: _text(a.headline, _small, _white, maxLines: 3)),
              ],
            ],
          ),
        ),
      ),
      if (more > 0) _at(24, 292, 400, '+ $more MORE ALERT${more == 1 ? '' : 'S'}', _small, _yellow),
    ];
  }

  Widget _icon(int code, double cx, double cy, double s, {bool day = true}) => Positioned(
    left: cx - s,
    top: cy - s,
    width: 2 * s,
    height: 2 * s,
    child: CustomPaint(painter: WeatherIcon(code, day: day)),
  );
}

/// A simple weather symbol for WMO [code] (the server's set), centred in its box, about half the box wide.
class WeatherIcon extends CustomPainter {
  final int code;
  final bool day;
  const WeatherIcon(this.code, {this.day = true});

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2, cy = size.height / 2, s = size.width / 2, r = s / 2;
    final fill = Paint();
    void circle(double x, double y, double rr, Color c) => canvas.drawCircle(Offset(x, y), rr, fill..color = c);

    void sun(double x, double y, double rr) {
      final ray = Paint()
        ..color = _yellow
        ..strokeWidth = rr > 12 ? 3 : 2;
      for (var k = 0; k < 8; k++) {
        final a = k * math.pi / 4, c = math.cos(a), sn = math.sin(a);
        canvas.drawLine(Offset(x + c * rr * 1.35, y + sn * rr * 1.35), Offset(x + c * rr * 1.75, y + sn * rr * 1.75), ray);
      }
      circle(x, y, rr, _yellow);
    }

    void moon(double x, double y, double rr) {
      canvas.saveLayer(Rect.fromCircle(center: Offset(x, y), radius: rr), Paint());
      circle(x, y, rr, _pale);
      canvas.drawCircle(Offset(x + rr / 2, y - rr / 3), rr, Paint()..blendMode = BlendMode.clear);
      canvas.restore();
    }

    void cloud(double x, double y, double w, Color c) {
      final h = w / 2;
      circle(x - w * 0.3, y, h * 0.6, c);
      circle(x + w / 12, y - h * 0.3, h * 0.8, c);
      circle(x + w * 0.3, y + h * 0.1, h * 0.5, c);
      canvas.drawRect(Rect.fromLTRB(x - w * 0.3, y, x + w * 0.3 + 1, y + h * 0.6), fill..color = c);
    }

    void drops(Color c, {bool snow = false}) {
      final line = Paint()
        ..color = c
        ..strokeWidth = 2;
      for (var k = -1; k <= 1; k++) {
        final x = cx + k * r * 2 / 3, y = cy + r * 2 / 3;
        if (snow) {
          circle(x, y + 2, (r / 8).clamp(1, 4), c);
        } else {
          canvas.drawLine(Offset(x + 2, y), Offset(x - 2, y + r / 2), line);
        }
      }
    }

    switch (code) {
      case 0 || 1:
        day ? sun(cx, cy, r * 0.6) : moon(cx, cy, r * 0.7);
        if (code == 1) cloud(cx + r / 2, cy + r / 3, s * 0.6, _cloud);
      case 2:
        day ? sun(cx - r / 3, cy - r / 3, r * 0.5) : moon(cx - r / 3, cy - r / 3, r * 0.5);
        cloud(cx + r / 6, cy + r / 6, s * 0.8, _cloud);
      case 45 || 48:
        for (var k = -1; k <= 1; k++) {
          canvas.drawRect(Rect.fromLTWH(cx - r, cy + k * r * 0.5, 2 * r, (r / 5).clamp(2, 8)), fill..color = _darkCloud);
        }
      case 51 || 53 || 55 || 56 || 57 || 61 || 63 || 66 || 80 || 81:
        cloud(cx, cy - r / 4, s, _cloud);
        drops(_blue);
      case 65 || 67 || 82:
        cloud(cx, cy - r / 4, s, _darkCloud);
        drops(_blue);
      case 71 || 73 || 75 || 77 || 85 || 86:
        cloud(cx, cy - r / 4, s, _cloud);
        drops(_white, snow: true);
      case 95 || 96 || 99:
        cloud(cx, cy - r / 4, s, _darkCloud);
        canvas.drawPath(
          Path()
            ..moveTo(cx + r / 6, cy + r / 6)
            ..lineTo(cx - r / 4, cy + r * 0.6)
            ..lineTo(cx, cy + r * 0.6)
            ..lineTo(cx - r / 6, cy + r)
            ..lineTo(cx + r / 3, cy + r * 0.4)
            ..lineTo(cx + r / 12, cy + r * 0.4)
            ..close(),
          fill..color = _yellow,
        );
      default:
        cloud(cx, cy, s, _cloud);
    }
  }

  @override
  bool shouldRepaint(WeatherIcon old) => old.code != code || old.day != day;
}
