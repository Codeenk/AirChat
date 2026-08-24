import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';

import '../../core/network/media_uploader.dart';
import '../../core/theme/colors.dart';

class VoiceNotePlayer extends StatefulWidget {
  /// "m:ss" duration label from the sender.
  final String duration;

  /// Encrypted media coordinates. When null (legacy/placeholder), the widget
  /// renders a disabled preview instead of a fake player.
  final String? mediaKey;
  final String? secretKeyHex;
  final String? nonceHex;
  final String backendUrl;
  final bool isMe;

  const VoiceNotePlayer({
    Key? key,
    required this.duration,
    this.mediaKey,
    this.secretKeyHex,
    this.nonceHex,
    this.backendUrl = '',
    this.isMe = false,
  }) : super(key: key);

  @override
  State<VoiceNotePlayer> createState() => _VoiceNotePlayerState();
}

class _VoiceNotePlayerState extends State<VoiceNotePlayer> {
  final AudioPlayer _player = AudioPlayer();
  StreamSubscription<Duration>? _posSub;
  StreamSubscription<Duration>? _durSub;
  StreamSubscription<PlayerState>? _stateSub;
  bool _isPlaying = false;
  bool _loading = false;
  bool _failed = false;
  Duration _position = Duration.zero;
  Duration _total = Duration.zero;

  bool get _playable =>
      widget.mediaKey != null &&
      widget.mediaKey!.isNotEmpty &&
      widget.secretKeyHex != null &&
      widget.nonceHex != null;

  @override
  void initState() {
    super.initState();
    _posSub = _player.onPositionChanged.listen((p) {
      if (mounted) setState(() => _position = p);
    });
    _durSub = _player.onDurationChanged.listen((d) {
      if (mounted) setState(() => _total = d);
    });
    _stateSub = _player.onPlayerStateChanged.listen((s) {
      if (!mounted) return;
      setState(() {
        _isPlaying = s == PlayerState.playing;
        if (s == PlayerState.completed) _position = Duration.zero;
      });
    });
  }

  Future<void> _toggle() async {
    if (_loading || !_playable) return;
    try {
      if (_isPlaying) {
        await _player.pause();
        setState(() => _isPlaying = false);
        return;
      }
      setState(() => _loading = true);
      if (_position == Duration.zero) {
        final bytes = await _decryptBytes();
        if (bytes == null) {
          setState(() { _loading = false; _failed = true; });
          return;
        }
        final tmp = File(
            '${Directory.systemTemp.path}/airchat_voice_${DateTime.now().millisecondsSinceEpoch}.m4a');
        await tmp.writeAsBytes(bytes, flush: true);
        await _player.play(DeviceFileSource(tmp.path));
      } else {
        await _player.resume();
        setState(() => _isPlaying = true);
      }
      setState(() => _loading = false);
    } catch (_) {
      if (mounted) setState(() { _loading = false; _failed = true; });
    }
  }

  Future<Uint8List?> _decryptBytes() async {
    // Reuse the shared encrypted-media downloader (cache + retry built in).
    return MediaPipeline.downloadAndDecrypt(
      fileKey: widget.mediaKey!,
      secretKeyHex: widget.secretKeyHex!,
      nonceHex: widget.nonceHex!,
      backendUrl: widget.backendUrl,
    );
  }

  @override
  void dispose() {
    _posSub?.cancel();
    _durSub?.cancel();
    _stateSub?.cancel();
    _player.dispose();
    super.dispose();
  }

  double get _progress =>
      _total.inMilliseconds > 0
          ? (_position.inMilliseconds / _total.inMilliseconds).clamp(0.0, 1.0)
          : 0.0;

  @override
  Widget build(BuildContext context) {
    final light = widget.isMe;
    final playBg = light ? AirColors.bubbleMeText : AirColors.surfaceElevated;
    final playFg = light ? AirColors.bubbleMe : AirColors.textPrimary;
    final playing = _isPlaying;

    return Container(
      width: 230,
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          CircleAvatar(
            backgroundColor: playBg,
            radius: 20,
            child: _loading
                ? SizedBox(
                    width: 16, height: 16,
                    child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: light ? AirColors.bubbleMe : playFg))
                : IconButton(
                    icon: Icon(
                      playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                      color: playFg,
                      size: 24,
                    ),
                    onPressed: _playable ? _toggle : null,
                  ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                SliderTheme(
                  data: SliderThemeData(
                    trackHeight: 3,
                    thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                    overlayShape: const RoundSliderOverlayShape(overlayRadius: 10),
                    activeTrackColor:
                        light ? AirColors.bubbleMeText : AirColors.textPrimary,
                    inactiveTrackColor: light
                        ? Colors.black.withOpacity(0.2)
                        : AirColors.textFaint.withOpacity(0.5),
                    thumbColor:
                        light ? AirColors.bubbleMeText : AirColors.textPrimary,
                  ),
                  child: Slider(
                    value: _progress,
                    onChanged: _playable && _total.inMilliseconds > 0
                        ? (v) {
                            _player.seek(_total * v);
                          }
                        : null,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(left: 8.0),
                  child: Text(
                    _failed
                        ? 'Unavailable'
                        : (playing || _position > Duration.zero
                            ? _fmt(_position)
                            : widget.duration),
                    style: TextStyle(
                        fontSize: 11,
                        color: light ? Colors.black54 : AirColors.textSecondary),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString();
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}
