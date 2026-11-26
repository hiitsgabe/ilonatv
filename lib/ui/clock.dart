import 'dart:async';

import 'package:flutter/material.dart';

/// HH:mm (24 h), redrawn on each minute boundary and on every resume.
class Clock extends StatefulWidget {
  const Clock({super.key});

  @override
  State<Clock> createState() => _ClockState();
}

class _ClockState extends State<Clock> {
  late Timer _timer;
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    // Dart timers run on monotonic time, which stops in deep sleep, so a wake
    // redraws and re-arms at once instead of waiting out the old timer.
    _lifecycle = AppLifecycleListener(onResume: _tick);
    _schedule();
  }

  void _tick() {
    _timer.cancel();
    setState(() {});
    _schedule();
  }

  void _schedule() {
    final now = DateTime.now();
    _timer = Timer(
      Duration(seconds: 60 - now.second, milliseconds: -now.millisecond),
      _tick,
    );
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    return Text(
      '${two(now.hour)}:${two(now.minute)}',
      style: const TextStyle(
        fontSize: 56,
        fontWeight: FontWeight.w600,
        color: Colors.white,
      ),
    );
  }
}
