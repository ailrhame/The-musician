import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:audioplayers/audioplayers.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const PianoApp());
}

class PianoApp extends StatelessWidget {
  const PianoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Piano Player',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0E0B14),
        primaryColor: const Color(0xFFB388FF),
        fontFamily: 'Roboto',
      ),
      home: const HomeScreen(),
    );
  }
}

// ============================================================
// Home Screen
// ============================================================

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final AudioPlayer _player = AudioPlayer();
  StreamSubscription<PlayerState>? _stateSub;
  StreamSubscription<Duration>? _posSub;

  String? _pickedPath;
  String? _pickedName;

  List<NoteEvent> _timeline = const [];
  bool _analyzing = false;
  bool _playing = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  int _activeNoteIndex = -1;

  Timer? _ticker;
  final Stopwatch _stopwatch = Stopwatch();

  @override
  void initState() {
    super.initState();
    _stateSub = _player.onPlayerStateChanged.listen((s) {
      if (!mounted) return;
      if (s == PlayerState.completed) {
        setState(() {
          _playing = false;
          _activeNoteIndex = -1;
        });
        _ticker?.cancel();
        _stopwatch.stop();
      }
    });
    _posSub = _player.onPositionChanged.listen((d) {
      if (!mounted) return;
      setState(() => _position = d);
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _stateSub?.cancel();
    _posSub?.cancel();
    _player.dispose();
    super.dispose();
  }

  Future<void> _pickAudio() async {
    if (Platform.isAndroid) {
      final status = await Permission.audio.request();
      if (!status.isGranted) {
        if (!mounted) return;
        _snack('صلاحية الصوت مرفوضة');
        return;
      }
    }
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['mp3', 'wav', 'm4a', 'aac', 'ogg', 'flac'],
    );
    if (result == null || result.files.single.path == null) return;
    final path = result.files.single.path!;
    final name = result.files.single.name;

    setState(() {
      _pickedPath = path;
      _pickedName = name;
      _timeline = const [];
      _activeNoteIndex = -1;
    });

    await _analyze(path);
  }

  Future<void> _analyze(String path) async {
    setState(() => _analyzing = true);
    try {
      final file = File(path);
      final size = await file.length();
      // Simulasi durasi: ~128kbps → 16000 bytes/detik
      final estimatedSeconds = math.max(2, size ~/ 16000);
      final seed = path.codeUnits.fold<int>(7, (a, b) => (a * 31 + b) & 0x7fffffff);
      final timeline = generateMelodyTimeline(
        durationSeconds: estimatedSeconds,
        seed: seed,
        tempoBpm: 110,
      );
      if (!mounted) return;
      setState(() {
        _timeline = timeline;
        _analyzing = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _analyzing = false);
      _snack('فشل تحليل الملف: $e');
    }
  }

  Future<void> _play() async {
    if (_pickedPath == null || _timeline.isEmpty) return;
    await _player.stop();
    await _player.setSourceDeviceFile(_pickedPath!);
    _duration = await _player.getDuration() ?? Duration.zero;
    await _player.resume();
    _stopwatch
      ..reset()
      ..start();
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(milliseconds: 33), (_) {
      _advanceActiveNote();
    });
    setState(() => _playing = true);
  }

  Future<void> _pause() async {
    await _player.pause();
    _ticker?.cancel();
    _stopwatch.stop();
    setState(() => _playing = false);
  }

  Future<void> _stop() async {
    await _player.stop();
    _ticker?.cancel();
    _stopwatch
      ..stop()
      ..reset();
    setState(() {
      _playing = false;
      _activeNoteIndex = -1;
      _position = Duration.zero;
    });
  }

  void _advanceActiveNote() {
    final ms = _stopwatch.elapsedMilliseconds;
    int idx = -1;
    for (int i = 0; i < _timeline.length; i++) {
      final n = _timeline[i];
      if (ms >= n.startMs && ms < n.startMs + n.durationMs) {
        idx = i;
        break;
      }
      if (ms < n.startMs) break;
    }
    if (idx != _activeNoteIndex && mounted) {
      setState(() => _activeNoteIndex = idx);
    }
  }

  void _snack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('بيانو تلقائي'),
          backgroundColor: Colors.black.withOpacity(0.4),
          elevation: 0,
        ),
        body: SafeArea(
          child: Column(
            children: [
              _buildTopPanel(),
              Expanded(
                child: PianoKeyboard(
                  timeline: _timeline,
                  activeIndex: _activeNoteIndex,
                  elapsedMs: _stopwatch.elapsedMilliseconds,
                ),
              ),
              _buildControls(),
              const SizedBox(height: 12),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTopPanel() {
    return Container(
      margin: const EdgeInsets.all(12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1524),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withOpacity(0.06)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.music_note, color: Color(0xFFB388FF)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _pickedName ?? 'لم يتم اختيار ملف',
                  style: const TextStyle(fontSize: 14),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _analyzing ? null : _pickAudio,
                  icon: const Icon(Icons.folder_open, size: 18),
                  label: Text(_analyzing ? 'جاري التحليل...' : 'اختر مقطعاً'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFFB388FF),
                    side: const BorderSide(color: Color(0xFFB388FF)),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.35),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  'نغمات: ${_timeline.length}',
                  style: const TextStyle(fontSize: 12, color: Colors.white70),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildControls() {
    final hasAudio = _pickedPath != null;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1524),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Text(
                _fmt(_position),
                style: const TextStyle(fontSize: 12, color: Colors.white70),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: LinearProgressIndicator(
                    value: _duration.inMilliseconds == 0
                        ? 0
                        : _position.inMilliseconds /
                            _duration.inMilliseconds,
                    backgroundColor: Colors.white.withOpacity(0.08),
                    valueColor: const AlwaysStoppedAnimation<Color>(
                      Color(0xFFB388FF),
                    ),
                  ),
                ),
              ),
              Text(
                _fmt(_duration),
                style: const TextStyle(fontSize: 12, color: Colors.white70),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton.filled(
                onPressed: (!hasAudio || _analyzing)
                    ? null
                    : (_playing ? _pause : _play),
                iconSize: 30,
                style: IconButton.styleFrom(
                  backgroundColor: const Color(0xFFB388FF),
                  foregroundColor: Colors.black,
                ),
                icon: Icon(_playing ? Icons.pause : Icons.play_arrow),
              ),
              const SizedBox(width: 16),
              IconButton(
                onPressed: hasAudio ? _stop : null,
                iconSize: 26,
                icon: const Icon(Icons.stop, color: Colors.white70),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}

// ============================================================
// Note model
// ============================================================

class NoteEvent {
  final String name; // e.g. C4, D#5
  final int midi;
  final int startMs;
  final int durationMs;
  const NoteEvent({
    required this.name,
    required this.midi,
    required this.startMs,
    required this.durationMs,
  });
}

// ============================================================
// Melody timeline generator
// ============================================================
// يستخرج خط زمني من النغمات اعتماداً على بذرة مشتقة من الملف.
// في build لاحق: استبدل هذه الدالة بـ FFT حقيقي أو native decoder.
// ============================================================

const List<String> _noteNames = [
  'C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B'
];

String midiToName(int midi) {
  final octave = (midi ~/ 12) - 1;
  final name = _noteNames[midi % 12];
  return '$name$octave';
}

List<NoteEvent> generateMelodyTimeline({
  required int durationSeconds,
  required int seed,
  int tempoBpm = 100,
}) {
  final rng = math.Random(seed);
  final beatMs = (60000 / tempoBpm).round();
  final total = durationSeconds * 1000;
  final List<NoteEvent> events = [];

  // C major pentatonic di sekitar C4–C6
  const List<int> scale = [60, 62, 64, 67, 69, 72, 74, 76, 79, 81];

  int t = 0;
  int prevIdx = 4;
  while (t < total) {
    final step = 1 + rng.nextInt(3); // 1..3 ketuk
    // random walk halus
    final drift = rng.nextInt(3) - 1;
    int idx = (prevIdx + drift).clamp(0, scale.length - 1);
    if (rng.nextDouble() < 0.15) {
      idx = rng.nextInt(scale.length);
    }
    prevIdx = idx;

    final midi = scale[idx];
    events.add(NoteEvent(
      name: midiToName(midi),
      midi: midi,
      startMs: t,
      durationMs: step * beatMs,
    ));
    t += step * beatMs;
  }
  return events;
}

// ============================================================
// Piano Keyboard
// ============================================================

class PianoKeyboard extends StatelessWidget {
  final List<NoteEvent> timeline;
  final int activeIndex;
  final int elapsedMs;

  const PianoKeyboard({
    super.key,
    required this.timeline,
    required this.activeIndex,
    required this.elapsedMs,
  });

  // Dua oktaf: C4..B5
  static const int startMidi = 60;
  static const int endMidi = 83;

  bool _isBlack(int midi) {
    final p = midi % 12;
    return p == 1 || p == 3 || p == 6 || p == 8 || p == 10;
  }

  Set<int> _activeMidis() {
    if (activeIndex < 0 || activeIndex >= timeline.length) return {};
    final n = timeline[activeIndex];
    return {n.midi};
  }

  @override
  Widget build(BuildContext context) {
    final active = _activeMidis();
    final whites = <int>[];
    final blacks = <int>[];
    for (int m = startMidi; m <= endMidi; m++) {
      if (_isBlack(m)) {
        blacks.add(m);
      } else {
        whites.add(m);
      }
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final whiteWidth = constraints.maxWidth / whites.length;
        final blackWidth = whiteWidth * 0.6;
        final blackHeight = constraints.maxHeight * 0.62;

        return Stack(
          children: [
            // white keys
            Row(
              children: whites.map((m) {
                final on = active.contains(m);
                return _PianoKey(
                  midi: m,
                  width: whiteWidth,
                  height: constraints.maxHeight,
                  isBlack: false,
                  active: on,
                );
              }).toList(),
            ),
            // black keys overlay
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: blackHeight,
              child: Stack(
                children: blacks.map((m) {
                  final on = active.contains(m);
                  // cari white key di sebelah kiri
                  int leftWhiteIdx = 0;
                  for (int i = 0; i < whites.length; i++) {
                    if (whites[i] < m) leftWhiteIdx = i;
                    if (whites[i] > m) break;
                  }
                  final left =
                      (leftWhiteIdx + 1) * whiteWidth - blackWidth / 2;
                  return Positioned(
                    left: left,
                    child: _PianoKey(
                      midi: m,
                      width: blackWidth,
                      height: blackHeight,
                      isBlack: true,
                      active: on,
                    ),
                  );
                }).toList(),
              ),
            ),
            // hint kalau timeline kosong
            if (timeline.isEmpty)
              Positioned.fill(
                child: IgnorePointer(
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.55),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Text(
                        'اختر مقطعاً موسيقياً لبدء العزف التلقائي',
                        style: TextStyle(fontSize: 13, color: Colors.white70),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _PianoKey extends StatelessWidget {
  final int midi;
  final double width;
  final double height;
  final bool isBlack;
  final bool active;

  const _PianoKey({
    required this.midi,
    required this.width,
    required this.height,
    required this.isBlack,
    required this.active,
  });

  @override
  Widget build(BuildContext context) {
    final baseColor = isBlack ? const Color(0xFF120E18) : const Color(0xFFF4F1FA);
    final activeColor =
        isBlack ? const Color(0xFF7C4DFF) : const Color(0xFFB388FF);

    final color = active ? activeColor : baseColor;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 60),
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: color,
        border: Border(
          left: BorderSide(
            color: Colors.black.withOpacity(isBlack ? 0.6 : 0.12),
            width: 1,
          ),
          right: BorderSide(
            color: Colors.black.withOpacity(isBlack ? 0.6 : 0.12),
            width: 1,
          ),
          bottom: BorderSide(
            color: Colors.black.withOpacity(0.4),
            width: 2,
          ),
        ),
        borderRadius: BorderRadius.vertical(
          bottom: Radius.circular(isBlack ? 3 : 6),
        ),
        boxShadow: active
            ? [
                BoxShadow(
                  color: activeColor.withOpacity(0.55),
                  blurRadius: 16,
                  spreadRadius: 1,
                ),
              ]
            : null,
      ),
      child: isBlack
          ? null
          : Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  midiToName(midi),
                  style: TextStyle(
                    fontSize: 10,
                    color: Colors.black.withOpacity(0.55),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
    );
  }
}