/*
 * Copyright (c) 2023-2026. Patrick Schmidt.
 * All rights reserved.
 */

import 'dart:async';

import 'package:appinio_video_player/appinio_video_player.dart';
import 'package:common/util/logger.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:video_player/video_player.dart';

/// TEMPORARY on-device A/B/C diagnostic for ipstream live video playback.
///
/// Exactly one engine is alive at a time. The card auto-cycles every 9s until a
/// chip is tapped (long-press a chip to resume cycling). Each pane renders its
/// live player state as an overlay so a screenshot alone tells us which engine
/// demuxes/decodes/renders the stream on the phone.
class WebcamIpStreamDebug extends StatefulWidget {
  const WebcamIpStreamDebug({
    super.key,
    required this.streamUri,
    required this.httpHeaders,
    this.stackChild = const [],
    this.onHidePressed,
  });

  final Uri streamUri;
  final Map<String, String> httpHeaders;
  final List<Widget> stackChild;
  final VoidCallback? onHidePressed;

  @override
  State<WebcamIpStreamDebug> createState() => _WebcamIpStreamDebugState();
}

enum _Engine { exo, mpvTuned, appinio }

class _WebcamIpStreamDebugState extends State<WebcamIpStreamDebug> {
  _Engine _engine = _Engine.exo;
  bool _pinned = false;
  Timer? _cycle;

  @override
  void initState() {
    super.initState();
    _cycle = Timer.periodic(const Duration(seconds: 9), (_) {
      if (_pinned) return;
      setState(() => _engine = _Engine.values[(_engine.index + 1) % _Engine.values.length]);
    });
    talker.info('IPDBG tri-pane debug card for ${widget.streamUri}');
  }

  @override
  void dispose() {
    _cycle?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    Widget pane = switch (_engine) {
      _Engine.exo => _ExoPane(
          key: ValueKey('exo-${widget.streamUri}'),
          uri: widget.streamUri,
          headers: widget.httpHeaders,
        ),
      _Engine.mpvTuned => _MpvPane(
          key: ValueKey('mpv-${widget.streamUri}'),
          uri: widget.streamUri,
          headers: widget.httpHeaders,
          tuned: true,
        ),
      _Engine.appinio => _AppinioPane(
          key: ValueKey('app-${widget.streamUri}'),
          uri: widget.streamUri,
          headers: widget.httpHeaders,
        ),
    };

    Widget body = LayoutBuilder(
      builder: (context, constraints) {
        return Stack(
          children: [
            if (constraints.hasBoundedHeight) Positioned.fill(child: pane) else AspectRatio(aspectRatio: 16 / 9, child: pane),
            Positioned(
              top: 4,
              left: 4,
              child: _ChipRow(
                engine: _engine,
                pinned: _pinned,
                onSelect: (e) => setState(() {
                  _engine = e;
                  _pinned = true;
                }),
                onLongPress: () => setState(() => _pinned = false),
              ),
            ),
          ],
        );
      },
    );

    return Stack(children: [body, ...widget.stackChild]);
  }
}

class _ChipRow extends StatelessWidget {
  const _ChipRow({
    required this.engine,
    required this.pinned,
    required this.onSelect,
    required this.onLongPress,
  });

  final _Engine engine;
  final bool pinned;
  final ValueChanged<_Engine> onSelect;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    ChoiceChip chip(_Engine e, String label) => ChoiceChip(
          label: Text(label, style: const TextStyle(fontSize: 11)),
          selected: engine == e,
          onSelected: (_) => onSelect(e),
        );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 4,
          children: [
            chip(_Engine.exo, 'A·Exo'),
            chip(_Engine.mpvTuned, 'B·mpv'),
            chip(_Engine.appinio, 'C·app'),
          ],
        ),
        if (!pinned)
          Container(
            color: Colors.black54,
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
            child: const Text('auto-cycling, tap to pin',
                style: TextStyle(fontSize: 10, color: Colors.white70)),
          ),
      ],
    );
  }
}

class _StatusOverlay extends StatelessWidget {
  const _StatusOverlay({required this.label, required this.status});
  final String label;
  final String status;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      bottom: 4,
      left: 4,
      right: 4,
      child: Container(
        width: double.infinity,
        color: Colors.black.withValues(alpha: 0.72),
        padding: const EdgeInsets.all(4),
        child: Text('$label :: $status',
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 11, color: Colors.white)),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// A: video_player -> ExoPlayer (what upstream would default to for a video URL)
// ---------------------------------------------------------------------------

class _ExoPane extends StatefulWidget {
  const _ExoPane({super.key, required this.uri, required this.headers});
  final Uri uri;
  final Map<String, String> headers;

  @override
  State<_ExoPane> createState() => _ExoPaneState();
}

class _ExoPaneState extends State<_ExoPane> {
  VideoPlayerController? _c;
  String _status = 'initializing…';
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    final c = VideoPlayerController.networkUrl(widget.uri, httpHeaders: widget.headers);
    _c = c;
    c.addListener(_onValue);
    c.initialize().timeout(const Duration(seconds: 20)).then((_) {
      talker.info('IPDBG A(Exo) initialized size=${c.value.size} dur=${c.value.duration}');
      if (mounted) setState(() {});
    }).catchError((e) {
      talker.warning('IPDBG A(Exo) init failed: $e');
      if (mounted) setState(() => _status = 'INIT ERROR: $e');
    });
    _poll = Timer.periodic(const Duration(seconds: 3), (_) => setState(() {}));
  }

  void _onValue() {
    if (!mounted) return;
    final v = _c!.value;
    _status = 'init=${v.isInitialized} playing=${v.isPlaying} pos=${v.position} '
        'dur=${v.duration} err=${v.errorDescription ?? "-"}';
    setState(() {});
  }

  @override
  void dispose() {
    _poll?.cancel();
    _c?.removeListener(_onValue);
    _c?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    return Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(color: Colors.black),
        if (c != null && c.value.isInitialized) VideoPlayer(c),
        _StatusOverlay(label: 'A video_player/ExoPlayer', status: _status),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// B: media_kit libmpv with live-stream tuned options + native property probe
// ---------------------------------------------------------------------------

class _MpvPane extends StatefulWidget {
  const _MpvPane({super.key, required this.uri, required this.headers, required this.tuned});
  final Uri uri;
  final Map<String, String> headers;
  final bool tuned;

  @override
  State<_MpvPane> createState() => _MpvPaneState();
}

class _MpvPaneState extends State<_MpvPane> {
  Player? _player;
  VideoController? _controller;
  NativePlayer? _native;
  StreamSubscription<String>? _errorSub;
  StreamSubscription<VideoParams>? _vpSub;
  StreamSubscription<bool>? _doneSub;
  Timer? _poll;
  String _status = 'opening…';
  String _mpvVersion = '?';
  int _completedCount = 0;

  @override
  void initState() {
    super.initState();
    MediaKit.ensureInitialized();
    final player = Player();
    _player = player;
    _controller = VideoController(player);
    _errorSub = player.stream.error.listen((e) {
      talker.warning('IPDBG B(mpv) stream.error: $e');
      if (mounted) setState(() => _status = 'MPV ERROR: $e');
    });
    _vpSub = player.stream.videoParams.listen((p) {
      talker.info('IPDBG B(mpv) videoParams ${p.dw}x${p.dh}');
      if (mounted) setState(() {});
    });
    _doneSub = player.stream.completed.listen((done) {
      if (done) _completedCount++;
      talker.info('IPDBG B(mpv) completed=$done #$_completedCount');
      if (mounted) setState(() {});
    });
    unawaited(_open());
    _poll = Timer.periodic(const Duration(seconds: 3), (_) => _probe());
  }

  Future<void> _open() async {
    try {
      final platform = _player!.platform;
      if (platform is NativePlayer) {
        _native = platform;
        await platform.setProperty('force-seekable', 'yes');
        if (widget.tuned) {
          await platform.setProperty('cache', 'yes');
          await platform.setProperty('demuxer-max-bytes', '50MiB');
          await platform.setProperty('demuxer-backward-read-bytes', '10MiB');
          await platform.setProperty('demuxer-lavf-o', 'analyzeduration=0:probesize=10000000');
          await platform.setProperty('stream-lavf-o', 'reconnect=1:reconnect_streamed=1');
        }
        _mpvVersion = await platform.getProperty('mpv-version');
        talker.info('IPDBG B(mpv) libmpv version=$_mpvVersion tuned=${widget.tuned}');
      }
      await _player!.open(Media(widget.uri.toString(), httpHeaders: widget.headers), play: true);
      talker.info('IPDBG B(mpv) open() returned, playing=${_player!.state.playing}');
      if (mounted) setState(() {});
    } catch (e) {
      talker.warning('IPDBG B(mpv) open failed: $e');
      if (mounted) setState(() => _status = 'OPEN FAILED: $e');
    }
  }

  Future<void> _probe() async {
    final native = _native;
    if (native == null) return;
    try {
      final time = await native.getProperty('time-pos');
      final frames = await native.getProperty('frame-counter');
      final eof = await native.getProperty('eof');
      final vp = _player?.state.videoParams;
      if (mounted) {
        setState(() => _status = 't=$time frames=$frames eof=$eof '
            'video=${vp?.dw}x${vp?.dh} mpv=$_mpvVersion done=$_completedCount');
      }
    } catch (e) {
      if (mounted) setState(() => _status = 'probe failed: $e');
    }
  }

  @override
  void dispose() {
    _poll?.cancel();
    _errorSub?.cancel();
    _vpSub?.cancel();
    _doneSub?.cancel();
    _player?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(color: Colors.black),
        Video(
          controller: _controller!,
          controls: NoVideoControls,
          fit: BoxFit.contain,
        ),
        _StatusOverlay(label: 'B media_kit${widget.tuned ? " tuned" : ""}', status: _status),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// C: appinio CustomVideoPlayer (cached_video_player_plus) — what the app
// already uses for its mp4 files page today
// ---------------------------------------------------------------------------

class _AppinioPane extends StatefulWidget {
  const _AppinioPane({super.key, required this.uri, required this.headers});
  final Uri uri;
  final Map<String, String> headers;

  @override
  State<_AppinioPane> createState() => _AppinioPaneState();
}

class _AppinioPaneState extends State<_AppinioPane> {
  CachedVideoPlayerPlusController? _c;
  CustomVideoPlayerController? _custom;
  String _status = 'initializing…';
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    final c = CachedVideoPlayerPlusController.networkUrl(widget.uri,
        httpHeaders: widget.headers, skipCache: true);
    _c = c;
    c.addListener(_onValue);
    _custom = CustomVideoPlayerController(context: context, videoPlayerController: c);
    c.initialize().timeout(const Duration(seconds: 20)).then((_) {
      c.play();
      talker.info('IPDBG C(appinio) initialized dur=${c.value.duration}');
      if (mounted) setState(() {});
    }).catchError((e) {
      talker.warning('IPDBG C(appinio) init failed: $e');
      if (mounted) setState(() => _status = 'INIT ERROR: $e');
    });
    _poll = Timer.periodic(const Duration(seconds: 3), (_) => setState(() {}));
  }

  void _onValue() {
    if (!mounted) return;
    final v = _c!.value;
    _status = 'init=${v.isInitialized} playing=${v.isPlaying} pos=${v.position} '
        'dur=${v.duration} err=${v.errorDescription ?? "-"}';
    setState(() {});
  }

  @override
  void dispose() {
    _poll?.cancel();
    _c?.removeListener(_onValue);
    _c?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    return Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(color: Colors.black),
        if (c != null && c.value.isInitialized) CustomVideoPlayer(customVideoPlayerController: _custom!),
        _StatusOverlay(label: 'C appinio/cached player', status: _status),
      ],
    );
  }
}
