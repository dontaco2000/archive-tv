import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../weather/weather.dart';
import 'weatherstar.dart';

/// The real WeatherStar 4000+ (github.com/netbymatt/ws4kp, MIT), shown in a WebView on the weather channel.
const weatherStarSite = 'https://weatherstar.netbymatt.com/';

/// Set once in main(): whether a WebView can run here, and (Windows) the WebView2 environment
/// with its data folder in the app's data dir (the install folder may not be writable) and the page muted.
bool webViewAvailable = false;
WebViewEnvironment? webViewEnvironment;

/// Lighter page (spec 5.9): radar kept, Future Radar and map-heavy screens off.
bool weatherStarLight = false;

/// Sets [webViewAvailable] (and the Windows environment); never throws: no WebView means native weather.
Future<void> initWebView({required bool windows, required String dataDir, void Function(String)? log}) async {
  try {
    if (windows) {
      final v = await WebViewEnvironment.getAvailableVersion();
      if (v == null) {
        log?.call('WebView2 runtime not installed: native weather screens');
        return;
      }
      webViewEnvironment = await WebViewEnvironment.create(
        settings: WebViewEnvironmentSettings(userDataFolder: dataDir, additionalBrowserArguments: '--mute-audio'),
      );
      log?.call('WebView2 $v ready');
    }
    webViewAvailable = true;
  } on Object catch (e) {
    log?.call('WebView unavailable ($e): native weather screens');
  }
}

/// Kiosk-mode page address for [place] at [lat]/[lon], using the project's documented permalink keys
/// (README "Sharing a permalink" / "Kiosk mode" / "Music doesn't auto play").
/// [light] (Fire TV Stick Lite, spec 5.9) keeps radar but drops Future Radar and the map-heavy screens.
Uri weatherStarUrl({required String place, required double lat, required double lon, bool light = false}) {
  final on = <String>{
    'hazards', 'current-weather', 'hourly-graph', 'local-forecast', 'extended-forecast', 'radar',
    if (!light) ...{'latest-observations', 'regional-forecast', 'almanac', 'spc-outlook', 'future-radar'},
  };
  const all = [
    'hazards', 'current-weather', 'latest-observations', 'hourly', 'hourly-graph', 'travel', 'regional-forecast',
    'local-forecast', 'extended-forecast', 'almanac', 'spc-outlook', 'radar', 'future-radar',
  ];
  return Uri.parse(weatherStarSite).replace(queryParameters: {
    for (final d in all) d: '${on.contains(d)}',
    'kiosk': 'true',
    'stickyKiosk': 'false',
    'viewMode': 'standard', // classic 4:3, the frame's own shape
    'units': 'us',
    'speed': '1.00',
    'scanLines': 'false',
    'mediaPlaying': 'false', // the channel's music comes from Archive through libmpv
    'mediaVolume': '0',
    'latLonQuery': place,
    'latLon': jsonEncode({'lat': lat, 'lon': lon}),
  });
}

/// Which weather picture to show: the web page unless the setting says native, no WebView
/// exists on this device, or the page failed to load on this tune.
bool useWebWeather(String weatherMode, {required bool webAvailable, required bool pageFailed}) =>
    weatherMode != 'native' && webAvailable && !pageFailed;

/// The weather channel's picture: the WeatherStar page when [web], with the native screens on top
/// until it has loaded; only the native screens otherwise (weatherMode native, no WebView, page failed).
class WeatherLayers extends StatelessWidget {
  final String place;
  final bool web, webLoaded;
  final Uri url;
  final Future<WeatherReport> Function() load;
  final VoidCallback onLoaded;
  final void Function(String why) onFailed;

  /// Tests replace the platform WebView, which can't run under flutter test.
  final Widget Function(Key key)? webViewForTest;

  const WeatherLayers({
    super.key,
    required this.place,
    required this.web,
    required this.webLoaded,
    required this.url,
    required this.load,
    required this.onLoaded,
    required this.onFailed,
    this.webViewForTest,
  });

  @override
  Widget build(BuildContext context) {
    // Both children are keyed by place (a new place reloads), so they need distinct tags.
    final webKey = ValueKey(('ws-web', place)), nativeKey = ValueKey(('ws-native', place));
    return Stack(fit: StackFit.expand, children: [
      if (web) webViewForTest?.call(webKey) ?? WeatherWebView(key: webKey, url: url, onLoaded: onLoaded, onFailed: onFailed),
      if (!web || !webLoaded) WeatherStarScreen(key: nativeKey, load: load),
    ]);
  }
}

/// The page itself, passive: it never takes focus or pointer input, so keys and the remote stay with the app.
class WeatherWebView extends StatefulWidget {
  final Uri url;
  final VoidCallback onLoaded;
  final void Function(String why) onFailed;
  final Duration timeout;
  const WeatherWebView({super.key, required this.url, required this.onLoaded, required this.onFailed, this.timeout = const Duration(seconds: 30)});

  @override
  State<WeatherWebView> createState() => _WeatherWebViewState();
}

class _WeatherWebViewState extends State<WeatherWebView> {
  Timer? _timeout;
  bool _loaded = false, _failed = false;

  @override
  void initState() {
    super.initState();
    _timeout = Timer(widget.timeout, () => _fail('no page after ${widget.timeout.inSeconds} s'));
  }

  // A main-frame error wins even after a load-stop (an error page also "loads").
  void _fail(String why) {
    if (_failed) return;
    _failed = true;
    _timeout?.cancel();
    widget.onFailed(why);
  }

  @override
  void dispose() {
    _timeout?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ExcludeFocus(
        child: IgnorePointer(
          child: InAppWebView(
            webViewEnvironment: webViewEnvironment,
            initialUrlRequest: URLRequest(url: WebUri.uri(widget.url)),
            initialSettings: InAppWebViewSettings(
              mediaPlaybackRequiresUserGesture: true,
              needInitialFocus: false,
              supportZoom: false,
              disableContextMenu: true,
              disableVerticalScroll: true,
              disableHorizontalScroll: true,
              transparentBackground: false,
              useHybridComposition: false, // texture layer: cheaper on the stick, overlays still draw on top
            ),
            onLoadStop: (_, _) {
              if (_loaded || _failed) return;
              _loaded = true;
              _timeout?.cancel();
              widget.onLoaded();
            },
            onReceivedError: (_, req, err) {
              if (req.isForMainFrame ?? true) _fail('${err.type}: ${err.description}');
            },
            onReceivedHttpError: (_, req, res) {
              if (req.isForMainFrame ?? true) _fail('HTTP ${res.statusCode}');
            },
          ),
        ),
      );
}
