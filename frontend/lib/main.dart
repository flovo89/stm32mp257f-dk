import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

const int _kWsPort       = 8765;
const int _kMaxAdcSamples = 256;

void main() => runApp(const _App());

class _App extends StatelessWidget {
  const _App();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'STM32 Pulse Generator',
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
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: Color(0xFF00B4D8)),
          ),
        ),
      ),
      home: const _PulseGenPage(),
    );
  }
}

// ── Connection state ──────────────────────────────────────────────────────────

enum _Conn { connecting, connected, disconnected }

// ── Frequency formatting ──────────────────────────────────────────────────────

String _fmtFreq(int hz) {
  if (hz == 0)         return 'OFF';
  if (hz >= 1000000)   return '${(hz / 1000000).toStringAsFixed(hz % 1000000 == 0 ? 0 : 3)} MHz';
  if (hz >= 1000)      return '${(hz / 1000).toStringAsFixed(hz % 1000 == 0 ? 0 : 3)} kHz';
  return '$hz Hz';
}

// ── Presets ───────────────────────────────────────────────────────────────────

const _presets = <(String, int)>[
  ('Off',    0),
  ('1 Hz',   1),
  ('1 kHz',  1000),
  ('10 kHz', 10000),
  ('100 kHz',100000),
  ('1 MHz',  1000000),
];

// ── Page ──────────────────────────────────────────────────────────────────────

class _PulseGenPage extends StatefulWidget {
  const _PulseGenPage();

  @override
  State<_PulseGenPage> createState() => _PulseGenPageState();
}

class _PulseGenPageState extends State<_PulseGenPage> {
  _Conn _connState = _Conn.disconnected;
  WebSocketChannel? _ch;
  StreamSubscription<dynamic>? _sub;
  Timer? _retryTimer;

  // Output state from M33
  int  _freq    = 0;
  bool _enabled = false;
  int  _tsMs    = 0;

  // Input state from M33
  int        _inFreqHz  = 0;
  final List<int> _adcSamples = [];

  // Input field
  final _freqCtrl = TextEditingController();

  String get _wsUrl {
    final host = Uri.base.host.isEmpty ? 'localhost' : Uri.base.host;
    return 'ws://$host:$_kWsPort';
  }

  @override
  void initState() {
    super.initState();
    _connect();
  }

  @override
  void dispose() {
    _retryTimer?.cancel();
    _sub?.cancel();
    _ch?.sink.close();
    _freqCtrl.dispose();
    super.dispose();
  }

  // ── WS management ───────────────────────────────────────────────────────────

  void _connect() {
    _sub?.cancel();
    _ch?.sink.close();
    setState(() => _connState = _Conn.connecting);
    try {
      _ch  = WebSocketChannel.connect(Uri.parse(_wsUrl));
      _sub = _ch!.stream.listen(
        _onMessage,
        onError: (_) => _scheduleRetry(),
        onDone:       _scheduleRetry,
      );
      setState(() => _connState = _Conn.connected);
    } catch (_) {
      _scheduleRetry();
    }
  }

  void _scheduleRetry() {
    if (!mounted) return;
    setState(() => _connState = _Conn.disconnected);
    _retryTimer?.cancel();
    _retryTimer = Timer(const Duration(seconds: 3), _connect);
  }

  void _onMessage(dynamic raw) {
    late Map<String, dynamic> msg;
    try {
      msg = jsonDecode(raw as String) as Map<String, dynamic>;
    } catch (_) { return; }

    final type = msg['type'] as String?;

    if (type == 'status') {
      setState(() {
        _freq      = (msg['freq_hz']    as num).toInt();
        _enabled   =  msg['enabled']    as bool;
        _tsMs      = (msg['ts_ms']      as num).toInt();
        _inFreqHz  = (msg['in_freq_hz'] as num? ?? 0).toInt();
      });
      return;
    }

    if (type == 'adc_chunk') {
      final samples = (msg['samples'] as List).cast<int>();
      setState(() {
        _adcSamples.addAll(samples);
        if (_adcSamples.length > _kMaxAdcSamples) {
          _adcSamples.removeRange(0, _adcSamples.length - _kMaxAdcSamples);
        }
      });
      return;
    }
  }

  // ── Commands ─────────────────────────────────────────────────────────────────

  void _setFreq(int hz) {
    if (_ch == null) return;
    _ch!.sink.add(jsonEncode({'cmd': 'pulse', 'freq_hz': hz}));
  }

  void _sendFromInput() {
    final hz = int.tryParse(_freqCtrl.text.trim());
    if (hz == null) return;
    _setFreq(hz.clamp(0, 1000000));
  }

  // ── Build ─────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final connected = _connState == _Conn.connected;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF161B22),
        surfaceTintColor: Colors.transparent,
        title: const Text(
          'STM32MP257F-DK — Pulse Generator',
          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
        actions: [
          _ConnChip(state: _connState),
          const SizedBox(width: 12),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [

            // ── Output status card ────────────────────────────────────────────
            Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Container(
                          width: 10, height: 10,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: _enabled
                                ? const Color(0xFF3FB950)
                                : const Color(0xFF8B949E),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          _enabled ? 'OUTPUT ACTIVE' : 'OUTPUT STOPPED',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 1.2,
                            color: _enabled
                                ? const Color(0xFF3FB950)
                                : const Color(0xFF8B949E),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Text(
                      _fmtFreq(_freq),
                      style: TextStyle(
                        fontSize: 48,
                        fontWeight: FontWeight.bold,
                        color: _enabled
                            ? const Color(0xFF00B4D8)
                            : const Color(0xFF484F58),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'PA5  ·  TIM2_CH4  ·  50 % duty',
                      style: TextStyle(
                        fontSize: 11,
                        color: Colors.white.withOpacity(0.35),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Uptime: ${(_tsMs / 1000).toStringAsFixed(1)} s',
                      style: TextStyle(
                        fontSize: 11,
                        color: Colors.white.withOpacity(0.25),
                      ),
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 12),

            // ── Preset buttons ────────────────────────────────────────────────
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'PRESETS',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 1.2,
                        color: Color(0xFF8B949E),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: _presets.map((p) {
                        final (label, hz) = p;
                        final isActive    = _freq == hz && (_enabled || hz == 0);
                        final isOff       = hz == 0;
                        return ElevatedButton(
                          onPressed: connected ? () => _setFreq(hz) : null,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: isActive
                                ? (isOff
                                    ? const Color(0xFF3D1F1F)
                                    : const Color(0xFF1F3D2F))
                                : const Color(0xFF21262D),
                            foregroundColor: isActive
                                ? (isOff
                                    ? const Color(0xFFF85149)
                                    : const Color(0xFF3FB950))
                                : const Color(0xFFE6EDF3),
                            side: BorderSide(
                              color: isActive
                                  ? (isOff
                                      ? const Color(0xFFF85149)
                                      : const Color(0xFF3FB950))
                                  : const Color(0xFF30363D),
                            ),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 16, vertical: 10),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(6)),
                          ),
                          child: Text(label,
                              style: const TextStyle(fontSize: 13)),
                        );
                      }).toList(),
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 12),

            // ── Custom frequency input ────────────────────────────────────────
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'CUSTOM FREQUENCY',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 1.2,
                        color: Color(0xFF8B949E),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _freqCtrl,
                            enabled: connected,
                            keyboardType: TextInputType.number,
                            inputFormatters: [
                              FilteringTextInputFormatter.digitsOnly,
                            ],
                            style: const TextStyle(fontSize: 14),
                            decoration: const InputDecoration(
                              isDense: true,
                              contentPadding: EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 10),
                              hintText: '1 – 1 000 000',
                              hintStyle: TextStyle(
                                  color: Color(0xFF484F58), fontSize: 13),
                              suffixText: 'Hz',
                              suffixStyle: TextStyle(
                                  color: Color(0xFF8B949E), fontSize: 12),
                            ),
                            onSubmitted: (_) => _sendFromInput(),
                          ),
                        ),
                        const SizedBox(width: 10),
                        ElevatedButton(
                          onPressed: connected ? _sendFromInput : null,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF1F6FEB),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(
                                horizontal: 20, vertical: 10),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(6)),
                          ),
                          child: const Text('Set',
                              style: TextStyle(fontSize: 13)),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Range: 0 Hz (off) to 1 000 000 Hz.  50 % duty cycle.',
                      style: TextStyle(
                          fontSize: 11,
                          color: Colors.white.withOpacity(0.3)),
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 12),

            // ── Input signal card ─────────────────────────────────────────────
            Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Header
                    Row(
                      children: [
                        const Text(
                          'INPUT SIGNAL',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 1.2,
                            color: Color(0xFF8B949E),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Text(
                          'PF15 trigger  ·  ADC3/PC7',
                          style: TextStyle(
                            fontSize: 11,
                            color: Colors.white.withOpacity(0.25),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),

                    // Input frequency display
                    Center(
                      child: Column(
                        children: [
                          Text(
                            _fmtFreq(_inFreqHz),
                            style: TextStyle(
                              fontSize: 36,
                              fontWeight: FontWeight.bold,
                              color: _inFreqHz > 0
                                  ? const Color(0xFF3FB950)
                                  : const Color(0xFF484F58),
                            ),
                          ),
                          const SizedBox(height: 4),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                width: 8, height: 8,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: _inFreqHz > 0
                                      ? const Color(0xFF3FB950)
                                      : const Color(0xFF484F58),
                                ),
                              ),
                              const SizedBox(width: 6),
                              Text(
                                _inFreqHz > 0
                                    ? 'SIGNAL DETECTED'
                                    : 'NO SIGNAL',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  letterSpacing: 1.2,
                                  color: _inFreqHz > 0
                                      ? const Color(0xFF3FB950)
                                      : const Color(0xFF484F58),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 20),

                    // ADC trace
                    const Text(
                      'ADC TRACE  ·  12-bit  ·  sampled on rising edge',
                      style: TextStyle(
                        fontSize: 10,
                        letterSpacing: 0.8,
                        color: Color(0xFF8B949E),
                      ),
                    ),
                    const SizedBox(height: 8),
                    ClipRect(
                      child: SizedBox(
                        height: 80,
                        child: _adcSamples.length >= 2
                            ? CustomPaint(
                                painter: _AdcPainter(
                                    List<int>.from(_adcSamples)),
                                size: Size.infinite,
                              )
                            : Container(
                                decoration: BoxDecoration(
                                  border: Border.all(
                                      color: const Color(0xFF30363D)),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Center(
                                  child: Text(
                                    'waiting for samples…',
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: Colors.white.withOpacity(0.2),
                                    ),
                                  ),
                                ),
                              ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    if (_adcSamples.isNotEmpty) ...[
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            'last: ${_adcSamples.last}  '
                            '(${(_adcSamples.last * 100 / 4095).toStringAsFixed(1)} %)',
                            style: TextStyle(
                              fontSize: 10,
                              color: Colors.white.withOpacity(0.35),
                            ),
                          ),
                          Text(
                            '${_adcSamples.length} samples',
                            style: TextStyle(
                              fontSize: 10,
                              color: Colors.white.withOpacity(0.25),
                            ),
                          ),
                        ],
                      ),
                    ],
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

// ── ADC trace painter ─────────────────────────────────────────────────────────

class _AdcPainter extends CustomPainter {
  _AdcPainter(this.samples);
  final List<int> samples;

  @override
  void paint(Canvas canvas, Size size) {
    if (samples.length < 2) return;

    // Background grid lines at 0 %, 25 %, 50 %, 75 %, 100 %
    final gridPaint = Paint()
      ..color = const Color(0xFF21262D)
      ..strokeWidth = 0.5;
    for (final frac in [0.0, 0.25, 0.5, 0.75, 1.0]) {
      final y = size.height * frac;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }

    // Sample trace
    final path = Path();
    final n = samples.length;
    for (int i = 0; i < n; i++) {
      final x = size.width  * i / (n - 1);
      final y = size.height * (1.0 - samples[i] / 4095.0);
      if (i == 0) path.moveTo(x, y);
      else        path.lineTo(x, y);
    }
    canvas.drawPath(
      path,
      Paint()
        ..color      = const Color(0xFF3FB950)
        ..strokeWidth = 1.5
        ..style       = PaintingStyle.stroke
        ..strokeJoin  = StrokeJoin.round,
    );

    // Min / max markers
    final minVal = samples.reduce(math.min);
    final maxVal = samples.reduce(math.max);
    final labelStyle = TextStyle(
      color:    Colors.white.withOpacity(0.4),
      fontSize: 9,
    );
    _drawLabel(canvas, '${maxVal}', 2, size.height * (1.0 - maxVal / 4095.0) - 10,
               labelStyle);
    _drawLabel(canvas, '${minVal}', 2, size.height * (1.0 - minVal / 4095.0) + 2,
               labelStyle);
  }

  void _drawLabel(Canvas canvas, String text, double x, double y,
                  TextStyle style) {
    final tp = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(x, y.clamp(0.0, double.infinity)));
  }

  @override
  bool shouldRepaint(_AdcPainter old) => true;
}

// ── Connection status chip ────────────────────────────────────────────────────

class _ConnChip extends StatelessWidget {
  const _ConnChip({required this.state});
  final _Conn state;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (state) {
      _Conn.connected    => ('Connected',    const Color(0xFF3FB950)),
      _Conn.connecting   => ('Connecting…',  const Color(0xFFD29922)),
      _Conn.disconnected => ('Disconnected', const Color(0xFFF85149)),
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
