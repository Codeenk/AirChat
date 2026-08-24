import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:record/record.dart';
import '../../core/theme/colors.dart';

enum VoiceRecorderState { idle, recording }

/// Hold-to-record voice note button. Emits the recorded file path + duration
/// on release (cancel on drag-away). Requires mic permission to be granted
/// by the caller before use.
class VoiceNoteRecorder extends StatefulWidget {
  final ValueChanged<VoiceRecording> onComplete;
  final VoidCallback? onPermissionDenied;

  const VoiceNoteRecorder({
    Key? key,
    required this.onComplete,
    this.onPermissionDenied,
  }) : super(key: key);

  @override
  State<VoiceNoteRecorder> createState() => _VoiceNoteRecorderState();
}

class VoiceRecording {
  final String path;
  final Duration duration;
  VoiceRecording({required this.path, required this.duration});
}

class _VoiceNoteRecorderState extends State<VoiceNoteRecorder> {
  final AudioRecorder _recorder = AudioRecorder();
  VoiceRecorderState _state = VoiceRecorderState.idle;
  DateTime? _startedAt;
  Timer? _tick;
  Duration _elapsed = Duration.zero;

  Future<void> _start() async {
    if (_state == VoiceRecorderState.recording) return;
    if (!await _recorder.hasPermission()) {
      widget.onPermissionDenied?.call();
      return;
    }
    _elapsed = Duration.zero;
    _startedAt = DateTime.now();
    await _recorder.start(
      const RecordConfig(encoder: AudioEncoder.aacLc, bitRate: 64000),
      path: _tempFilePath(),
    );
    setState(() => _state = VoiceRecorderState.recording);
    _tick = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (mounted && _startedAt != null) {
        setState(() => _elapsed = DateTime.now().difference(_startedAt!));
      }
    });
  }

  String _tempFilePath() {
    final ts = DateTime.now().millisecondsSinceEpoch;
    return '${Directory.systemTemp.path}/airchat_voice_$ts.m4a';
  }

  Future<void> _stop({required bool send}) async {
    if (_state != VoiceRecorderState.recording) return;
    _tick?.cancel();
    _tick = null;
    final duration = _elapsed;
    try {
      final path = await _recorder.stop();

      setState(() => _state = VoiceRecorderState.idle);
      if (send && path != null && duration.inMilliseconds > 600) {
        widget.onComplete(VoiceRecording(path: path, duration: duration));
      }
    } catch (_) {
      if (mounted) setState(() => _state = VoiceRecorderState.idle);
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    _recorder.dispose();
    super.dispose();
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString();
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    if (_state == VoiceRecorderState.recording) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.mic, color: AirColors.error, size: 20),
          const SizedBox(width: 6),
          Text(
            _fmt(_elapsed),
            style: const TextStyle(color: AirColors.textPrimary, fontSize: 13),
          ),
          const SizedBox(width: 4),
          GestureDetector(
            onTap: () => _stop(send: false),
            child: const Icon(Icons.delete_outline,
                color: AirColors.textSecondary, size: 20),
          ),
        ],
      );
    }
    return GestureDetector(
      onLongPressStart: (_) => _start(),
      onLongPressEnd: (_) => _stop(send: true),
      onLongPressCancel: () => _stop(send: false),
      child: const Icon(Icons.mic_none_rounded,
          color: AirColors.textSecondary, size: 24),
    );
  }
}
