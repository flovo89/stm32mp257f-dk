import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

// ── Config ────────────────────────────────────────────────────────────────────

const int    _kWsPort    = 8765;
const int    _kMaxPoints = 150;  // 3 seconds of history at 50 Hz
const double _kAdcMaxV   = 1.8;

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
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFF0D1117),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: Color(0xFF30363D)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: Color(0xFF30363D)),
          ),
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

  // ADC/encoder data
  final List<FlSpot> _ch0 = [];
  final List<FlSpot> _ch1 = [];
  final List<FlSpot> _enc = [];
  double _ch0V  = 0;
  double _ch1V  = 0;
  int    _encPos = 0;
  int    _encIdx = 0;

  // Motor status
  double _speedRads = 0;
  double _speedRpm  = 0;
  double _angleDeg  = 0;
  double _idMa      = 0;
  double _iqMa      = 0;
  String _motorState = 'off';
  int    _fault      = 0;
  final List<FlSpot> _spdPts  = [];
  final List<FlSpot> _iqPts   = [];

  // Motor command UI
  String _cmdMode      = 'off';
  final _spCtrl        = TextEditingController(text: '0');
  bool   _cmdSending   = false;

  // ── WS URL ──────────────────────────────────────────────────────────────

  String get _wsUrl {
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
    _spCtrl.dispose();
    super.dispose();
  }

  // ── WebSocket management ─────────────────────────────────────────────────

  void _connect() {
    _sub?.cancel();
    _channel?.sink.close();
    setState(() => _state = _ConnState.connecting);
    try {
      _channel = WebSocketChannel.connect(Uri.parse(_wsUrl));
      _sub = _channel!.stream.listen(
        _onMessage,
        onError: (_) => _scheduleRetry(),
        onDone:       _scheduleRetry,
      );
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
    } catch (_) { return; }

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

      } else if (msg['type'] == 'motor_status') {
        _speedRads  = ((msg['speed_rads'] as num?) ?? 0).toDouble();
        _speedRpm   = ((msg['speed_rpm']  as num?) ?? 0).toDouble();
        _angleDeg   = ((msg['angle_deg']  as num?) ?? 0).toDouble();
        _idMa       = ((msg['id_ma']      as num?) ?? 0).toDouble();
        _iqMa       = ((msg['iq_ma']      as num?) ?? 0).toDouble();
        _motorState = (msg['state'] as String?) ?? 'off';
        _fault      = (msg['fault']  as num?)?.toInt() ?? 0;
        _push(_spdPts, FlSpot(t, _speedRpm));
        _push(_iqPts,  FlSpot(t, _iqMa));
      }
    });
  }

  void _push(List<FlSpot> list, FlSpot spot) {
    list.add(spot);
    if (list.length > _kMaxPoints) list.removeAt(0);
  }

  List<FlSpot> _rel(List<FlSpot> raw) {
    if (raw.isEmpty) return const [];
    final base = raw.first.x;
    return raw.map((s) => FlSpot(s.x - base, s.y)).toList();
  }

  // ── Motor command ────────────────────────────────────────────────────────

  void _sendMotorCmd() {
    if (_channel == null) return;
    final sp = double.tryParse(_spCtrl.text) ?? 0.0;
    final cmd = jsonEncode({
      'cmd':      'motor',
      'mode':     _cmdMode,
      'setpoint': sp,
    });
    _channel!.sink.add(cmd);
    setState(() => _cmdSending = true);
    Future.delayed(const Duration(milliseconds: 300),
        () => setState(() => _cmdSending = false));
  }

  // ── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF161B22),
        surfaceTintColor: Colors.transparent,
        title: const Text(
          'STM32MP257F-DK — M33 FOC Dashboard',
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
            // ── Motor control card ──────────────────────────────────────────
            _MotorControlCard(
              motorState: _motorState,
              speedRpm:   _speedRpm,
              speedRads:  _speedRads,
              angleDeg:   _angleDeg,
              idMa:       _idMa,
              iqMa:       _iqMa,
              fault:      _fault,
              cmdMode:    _cmdMode,
              onModeChanged: (m) => setState(() => _cmdMode = m),
              spCtrl:     _spCtrl,
              onSend:     _state == _ConnState.connected ? _sendMotorCmd : null,
              sending:    _cmdSending,
            ),
            const SizedBox(height: 12),
            // ── Speed chart ─────────────────────────────────────────────────
            _ChartCard(
              title:    'Motor speed',
              valueStr: '${_speedRpm.toStringAsFixed(1)} RPM',
              spots:    _rel(_spdPts),
              color:    const Color(0xFFFF7B54),
              minY:     null,
              maxY:     null,
              yUnit:    'RPM',
            ),
            const SizedBox(height: 12),
            // ── Iq chart ────────────────────────────────────────────────────
            _ChartCard(
              title:    'q-axis current (torque)',
              valueStr: '${_iqMa.toStringAsFixed(1)} mA',
              spots:    _rel(_iqPts),
              color:    const Color(0xFFFF6B6B),
              minY:     null,
              maxY:     null,
              yUnit:    'mA',
            ),
            const SizedBox(height: 12),
            // ── ADC charts ─────────────────────────────────────────────────
            _ChartCard(
              title:    'Phase A current sense — PC7/INP9 (INA240)',
              valueStr: '${_ch0V.toStringAsFixed(3)} V',
              spots:    _rel(_ch0),
              color:    const Color(0xFF58A6FF),
              minY:     0,
              maxY:     _kAdcMaxV,
              yUnit:    'V',
            ),
            const SizedBox(height: 12),
            _ChartCard(
              title:    'Phase B current sense — PF11/INP6 (INA240)',
              valueStr: '${_ch1V.toStringAsFixed(3)} V',
              spots:    _rel(_ch1),
              color:    const Color(0xFF3FB950),
              minY:     0,
              maxY:     _kAdcMaxV,
              yUnit:    'V',
            ),
            const SizedBox(height: 12),
            _ChartCard(
              title:    'Encoder position (A=PF15  B=PG5)',
              valueStr: '$_encPos counts  •  $_encIdx rev',
              spots:    _rel(_enc),
              color:    const Color(0xFFFF9F1C),
              minY:     null,
              maxY:     null,
              yUnit:    'cnt',
            ),
          ],
        ),
      ),
    );
  }
}

// ── Motor control card ────────────────────────────────────────────────────────

class _MotorControlCard extends StatelessWidget {
  const _MotorControlCard({
    required this.motorState,
    required this.speedRpm,
    required this.speedRads,
    required this.angleDeg,
    required this.idMa,
    required this.iqMa,
    required this.fault,
    required this.cmdMode,
    required this.onModeChanged,
    required this.spCtrl,
    required this.onSend,
    required this.sending,
  });

  final String   motorState;
  final double   speedRpm, speedRads, angleDeg, idMa, iqMa;
  final int      fault;
  final String   cmdMode;
  final void Function(String) onModeChanged;
  final TextEditingController spCtrl;
  final VoidCallback? onSend;
  final bool     sending;

  Color get _stateColor => switch (motorState) {
    'run'   => const Color(0xFF3FB950),
    'fault' => const Color(0xFFF85149),
    _       => const Color(0xFF8B949E),
  };

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Status row ──────────────────────────────────────────────────
            Row(
              children: [
                Container(
                  width: 10, height: 10,
                  decoration: BoxDecoration(
                    color: _stateColor, shape: BoxShape.circle),
                ),
                const SizedBox(width: 8),
                Text(
                  'Motor — ${motorState.toUpperCase()}',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                    color: _stateColor,
                  ),
                ),
                if (fault != 0) ...[
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF85149).withOpacity(0.2),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text('FAULT 0x${fault.toRadixString(16)}',
                        style: const TextStyle(
                            color: Color(0xFFF85149), fontSize: 11)),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 12),
            // ── Status values ────────────────────────────────────────────────
            Wrap(
              spacing: 24,
              runSpacing: 8,
              children: [
                _StatVal('Speed',
                    '${speedRpm.toStringAsFixed(1)} RPM\n'
                    '${speedRads.toStringAsFixed(2)} rad/s'),
                _StatVal('Angle', '${angleDeg.toStringAsFixed(1)}°'),
                _StatVal('Id',    '${idMa.toStringAsFixed(1)} mA'),
                _StatVal('Iq',    '${iqMa.toStringAsFixed(1)} mA'),
              ],
            ),
            const SizedBox(height: 16),
            const Divider(color: Color(0xFF30363D)),
            const SizedBox(height: 12),
            // ── Command row ──────────────────────────────────────────────────
            Row(
              children: [
                // Mode selector
                DropdownButton<String>(
                  value: cmdMode,
                  dropdownColor: const Color(0xFF161B22),
                  underline: const SizedBox(),
                  items: const [
                    DropdownMenuItem(value: 'off',   child: Text('Off')),
                    DropdownMenuItem(value: 'speed', child: Text('Speed')),
                    DropdownMenuItem(value: 'angle', child: Text('Angle')),
                  ],
                  onChanged: (v) { if (v != null) onModeChanged(v); },
                ),
                const SizedBox(width: 12),
                // Setpoint input
                if (cmdMode != 'off') ...[
                  SizedBox(
                    width: 120,
                    child: TextField(
                      controller: spCtrl,
                      keyboardType: const TextInputType.numberWithOptions(
                          decimal: true, signed: true),
                      style: const TextStyle(fontSize: 13),
                      decoration: InputDecoration(
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 8),
                        suffixText: cmdMode == 'speed' ? 'rad/s' : 'rad',
                        suffixStyle: const TextStyle(
                            color: Color(0xFF8B949E), fontSize: 11),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                ],
                // Send button
                ElevatedButton(
                  onPressed: sending ? null : onSend,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: cmdMode == 'off'
                        ? const Color(0xFF21262D)
                        : const Color(0xFF238636),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 8),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(6)),
                  ),
                  child: Text(
                    sending ? 'Sent ✓' : (cmdMode == 'off' ? 'Stop' : 'Send'),
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _StatVal extends StatelessWidget {
  const _StatVal(this.label, this.value);
  final String label, value;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: const TextStyle(
                fontSize: 11, color: Color(0xFF8B949E))),
        const SizedBox(height: 2),
        Text(value,
            style: const TextStyle(
                fontSize: 13, fontWeight: FontWeight.w600)),
      ],
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
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(title,
                    style: const TextStyle(
                        fontSize: 12, fontWeight: FontWeight.w500,
                        color: Color(0xFF8B949E))),
                ),
                const SizedBox(width: 8),
                Text(valueStr,
                    style: TextStyle(
                        fontSize: 14, fontWeight: FontWeight.bold,
                        color: color)),
              ],
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 140,
              child: isEmpty
                  ? Center(
                      child: Text('Waiting for data…',
                          style: TextStyle(
                              color: Colors.white.withOpacity(0.2))))
                  : LineChart(
                      duration: const Duration(milliseconds: 50),
                      LineChartData(
                        minX: _xMin, maxX: _xMax,
                        minY: yLo,   maxY: yHi,
                        clipData: const FlClipData.all(),
                        lineBarsData: [
                          LineChartBarData(
                            spots:           spots,
                            isCurved:        true,
                            curveSmoothness: 0.1,
                            color:           color,
                            barWidth:        1.5,
                            dotData: const FlDotData(show: false),
                            belowBarData: BarAreaData(
                              show:  true,
                              color: color.withOpacity(0.07)),
                          ),
                        ],
                        gridData: FlGridData(
                          show: true,
                          getDrawingHorizontalLine: (_) =>
                              FlLine(color: Colors.white.withOpacity(0.07),
                                     strokeWidth: 0.5),
                          getDrawingVerticalLine: (_) =>
                              FlLine(color: Colors.white.withOpacity(0.07),
                                     strokeWidth: 0.5),
                        ),
                        borderData: FlBorderData(
                          show: true,
                          border: Border.all(
                              color: Colors.white.withOpacity(0.1))),
                        titlesData: FlTitlesData(
                          topTitles: AxisTitles(
                              sideTitles: SideTitles(showTitles: false)),
                          rightTitles: AxisTitles(
                              sideTitles: SideTitles(showTitles: false)),
                          bottomTitles: AxisTitles(
                            sideTitles: SideTitles(
                              showTitles:   true,
                              reservedSize: 22,
                              interval:     1,
                              getTitlesWidget: (val, _) {
                                final ago = (val - _xMax).round();
                                if (ago % 3 != 0) return const SizedBox.shrink();
                                return Padding(
                                  padding: const EdgeInsets.only(top: 4),
                                  child: Text('${ago}s',
                                      style: TextStyle(fontSize: 10,
                                          color: Colors.white.withOpacity(0.3))),
                                );
                              },
                            ),
                          ),
                          leftTitles: AxisTitles(
                            sideTitles: SideTitles(
                              showTitles:   true,
                              reservedSize: 46,
                              getTitlesWidget: (val, meta) {
                                if (val == meta.min || val == meta.max) {
                                  return const SizedBox.shrink();
                                }
                                final label = minY != null
                                    ? val.toStringAsFixed(1)
                                    : val.toInt().toString();
                                return Text(label,
                                    style: TextStyle(fontSize: 10,
                                        color: Colors.white.withOpacity(0.3)),
                                    textAlign: TextAlign.right);
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
