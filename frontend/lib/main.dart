import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

// ── Config ────────────────────────────────────────────────────────────────────

const int    _kWsPort    = 8765;
const int    _kMaxPoints = 60;   // seconds of history shown
const double _kAdcMaxV   = 3.3;

// ── Entry point ───────────────────────────────────────────────────────────────

void main() => runApp(const _DashboardApp());

class _DashboardApp extends StatelessWidget {
  const _DashboardApp();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'STM32 M33 Dashboard',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0D1117),
        cardColor: const Color(0xFF161B22),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF00B4D8),
          brightness: Brightness.dark,
          surface: const Color(0xFF161B22),
        ),
        cardTheme: CardThemeData(
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: const BorderSide(color: Color(0xFF30363D)),
          ),
        ),
        textTheme: const TextTheme(
          bodyMedium: TextStyle(color: Color(0xFFE6EDF3)),
        ),
      ),
      home: const _DashboardPage(),
    );
  }
}

// ── Connection state ──────────────────────────────────────────────────────────

enum _ConnState { connecting, connected, disconnected }

// ── Dashboard page ────────────────────────────────────────────────────────────

class _DashboardPage extends StatefulWidget {
  const _DashboardPage();

  @override
  State<_DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<_DashboardPage> {
  _ConnState _state = _ConnState.disconnected;
  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _sub;
  Timer? _retryTimer;

  // Raw data buffers — store (firmware_ts_seconds, value) pairs
  final List<FlSpot> _ch0 = [];
  final List<FlSpot> _ch1 = [];
  final List<FlSpot> _enc = [];

  // Latest values for numeric display
  double _ch0V  = 0;
  double _ch1V  = 0;
  int    _encPos = 0;
  int    _encIdx = 0;

  // ── WS URL derived from the browser's own hostname ──────────────────────

  String get _wsUrl {
    // Uri.base gives the URL of the serving page
    // (e.g. http://192.168.1.100:8080/) so .host gives the board IP.
    final host = Uri.base.host.isEmpty ? 'localhost' : Uri.base.host;
    return 'ws://$host:$_kWsPort';
  }

  // ── Lifecycle ────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _connect();
  }

  @override
  void dispose() {
    _retryTimer?.cancel();
    _sub?.cancel();
    _channel?.sink.close();
    super.dispose();
  }

  // ── WebSocket management ─────────────────────────────────────────────────

  void _connect() {
    _sub?.cancel();
    _channel?.sink.close();
    setState(() => _state = _ConnState.connecting);

    try {
      final uri = Uri.parse(_wsUrl);
      _channel = WebSocketChannel.connect(uri);
      _sub = _channel!.stream.listen(
        _onMessage,
        onError: (_) => _scheduleRetry(),
        onDone:       _scheduleRetry,
      );
      // WebSocketChannel.connect doesn't throw immediately — treat the listen
      // as success until the stream errors.
      setState(() => _state = _ConnState.connected);
    } catch (_) {
      _scheduleRetry();
    }
  }

  void _scheduleRetry() {
    if (!mounted) return;
    setState(() => _state = _ConnState.disconnected);
    _retryTimer?.cancel();
    _retryTimer = Timer(const Duration(seconds: 3), _connect);
  }

  // ── Data ingestion ───────────────────────────────────────────────────────

  void _onMessage(dynamic raw) {
    late Map<String, dynamic> msg;
    try {
      msg = jsonDecode(raw as String) as Map<String, dynamic>;
    } catch (_) {
      return;
    }

    final double t = ((msg['ts_ms'] as num?) ?? 0) / 1000.0;

    setState(() {
      if (msg['type'] == 'adc') {
        _ch0V = ((msg['ch0_v'] as num?) ?? 0).toDouble();
        _ch1V = ((msg['ch1_v'] as num?) ?? 0).toDouble();
        _push(_ch0, FlSpot(t, _ch0V));
        _push(_ch1, FlSpot(t, _ch1V));
      } else if (msg['type'] == 'encoder') {
        _encPos = (msg['position']    as num?)?.toInt() ?? 0;
        _encIdx = (msg['index_count'] as num?)?.toInt() ?? 0;
        _push(_enc, FlSpot(t, _encPos.toDouble()));
      }
    });
  }

  void _push(List<FlSpot> list, FlSpot spot) {
    list.add(spot);
    if (list.length > _kMaxPoints) list.removeAt(0);
  }

  // Remap so the oldest visible point is always at x = 0.
  List<FlSpot> _rel(List<FlSpot> raw) {
    if (raw.isEmpty) return const [];
    final base = raw.first.x;
    return raw.map((s) => FlSpot(s.x - base, s.y)).toList();
  }

  // ── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final ch0 = _rel(_ch0);
    final ch1 = _rel(_ch1);
    final enc = _rel(_enc);

    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF161B22),
        surfaceTintColor: Colors.transparent,
        title: const Text(
          'STM32MP257F-DK — M33 Dashboard',
          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
        actions: [
          _StatusChip(state: _state),
          const SizedBox(width: 12),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _ChartCard(
              title:    'ADC ch0 — PC7 (INP9)',
              valueStr: '${_ch0V.toStringAsFixed(3)} V',
              spots:    ch0,
              color:    const Color(0xFF58A6FF),
              minY:     0,
              maxY:     _kAdcMaxV,
              yUnit:    'V',
            ),
            const SizedBox(height: 12),
            _ChartCard(
              title:    'ADC ch1 — PF11 (INP6)',
              valueStr: '${_ch1V.toStringAsFixed(3)} V',
              spots:    ch1,
              color:    const Color(0xFF3FB950),
              minY:     0,
              maxY:     _kAdcMaxV,
              yUnit:    'V',
            ),
            const SizedBox(height: 12),
            _ChartCard(
              title:    'Encoder position (A=PF13  B=PF14  Z=PF15)',
              valueStr: '$_encPos  counts  •  $_encIdx rev',
              spots:    enc,
              color:    const Color(0xFFFF9F1C),
              minY:     null,   // auto-scale
              maxY:     null,
              yUnit:    'cnt',
            ),
          ],
        ),
      ),
    );
  }
}

// ── Connection status chip ────────────────────────────────────────────────────

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.state});

  final _ConnState state;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (state) {
      _ConnState.connected    => ('Connected',    const Color(0xFF3FB950)),
      _ConnState.connecting   => ('Connecting…',  const Color(0xFFD29922)),
      _ConnState.disconnected => ('Disconnected', const Color(0xFFF85149)),
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8, height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(label, style: TextStyle(fontSize: 12, color: color)),
      ],
    );
  }
}

// ── Chart card ────────────────────────────────────────────────────────────────

class _ChartCard extends StatelessWidget {
  const _ChartCard({
    required this.title,
    required this.valueStr,
    required this.spots,
    required this.color,
    required this.minY,
    required this.maxY,
    required this.yUnit,
  });

  final String       title;
  final String       valueStr;
  final List<FlSpot> spots;
  final Color        color;
  final double?      minY;
  final double?      maxY;
  final String       yUnit;

  double get _xMax => spots.isEmpty ? (_kMaxPoints - 1).toDouble() : spots.last.x;
  double get _xMin => max(0.0, _xMax - (_kMaxPoints - 1));

  // Auto Y bounds with padding; falls back to ±1 on empty data.
  (double lo, double hi) get _yBounds {
    if (minY != null && maxY != null) return (minY!, maxY!);
    if (spots.isEmpty) return (-1, 1);
    final ys  = spots.map((s) => s.y).toList();
    final lo  = ys.reduce(min);
    final hi  = ys.reduce(max);
    final pad = max(5.0, (hi - lo).abs() * 0.15);
    return (lo - pad, hi + pad);
  }

  @override
  Widget build(BuildContext context) {
    final (yLo, yHi) = _yBounds;
    final isEmpty    = spots.isEmpty;

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 14, 14, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Header row ──────────────────────────────────────────────
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: Color(0xFF8B949E),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  valueStr,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: color,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            // ── Chart ───────────────────────────────────────────────────
            SizedBox(
              height: 180,
              child: isEmpty
                  ? Center(
                      child: Text(
                        'Waiting for data…',
                        style: TextStyle(color: Colors.white.withOpacity(0.2)),
                      ),
                    )
                  : LineChart(
                      duration: const Duration(milliseconds: 80),
                      LineChartData(
                        minX: _xMin,
                        maxX: _xMax,
                        minY: yLo,
                        maxY: yHi,
                        clipData: const FlClipData.all(),
                        lineBarsData: [
                          LineChartBarData(
                            spots:           spots,
                            isCurved:        true,
                            curveSmoothness: 0.15,
                            color:           color,
                            barWidth:        2,
                            dotData:         const FlDotData(show: false),
                            belowBarData:    BarAreaData(
                              show:  true,
                              color: color.withOpacity(0.07),
                            ),
                          ),
                        ],
                        gridData: FlGridData(
                          show: true,
                          drawVerticalLine: true,
                          getDrawingHorizontalLine: (_) =>
                              FlLine(color: Colors.white.withOpacity(0.07), strokeWidth: 0.5),
                          getDrawingVerticalLine: (_) =>
                              FlLine(color: Colors.white.withOpacity(0.07), strokeWidth: 0.5),
                        ),
                        borderData: FlBorderData(
                          show: true,
                          border: Border.all(color: Colors.white.withOpacity(0.1)),
                        ),
                        titlesData: FlTitlesData(
                          topTitles:   AxisTitles(sideTitles: SideTitles(showTitles: false)),
                          rightTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
                          bottomTitles: AxisTitles(
                            sideTitles: SideTitles(
                              showTitles:   true,
                              reservedSize: 22,
                              interval:     10,
                              getTitlesWidget: (val, _) {
                                final ago = (val - _xMax).round();
                                return Padding(
                                  padding: const EdgeInsets.only(top: 4),
                                  child: Text(
                                    '${ago}s',
                                    style: TextStyle(
                                      fontSize: 10,
                                      color: Colors.white.withOpacity(0.3),
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
                          leftTitles: AxisTitles(
                            sideTitles: SideTitles(
                              showTitles:   true,
                              reservedSize: 46,
                              getTitlesWidget: (val, meta) {
                                // Skip labels that would overlap the edges
                                if (val == meta.min || val == meta.max) {
                                  return const SizedBox.shrink();
                                }
                                final label = minY != null
                                    ? val.toStringAsFixed(1)
                                    : val.toInt().toString();
                                return Text(
                                  label,
                                  style: TextStyle(
                                    fontSize: 10,
                                    color: Colors.white.withOpacity(0.3),
                                  ),
                                  textAlign: TextAlign.right,
                                );
                              },
                            ),
                          ),
                        ),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

