/*
 * Copyright (c) 2023-2026. Patrick Schmidt.
 * All rights reserved.
 */

import 'dart:async';
import 'dart:io';

import 'package:common/data/model/hive/machine.dart';
import 'package:common/data/model/moonraker_db/webcam_info.dart';
import 'package:common/network/dio_provider.dart';
import 'package:common/network/jrpc_client_provider.dart';
import 'package:common/network/json_rpc_client.dart';
import 'package:common/util/extensions/uri_extension.dart';
import 'package:common/util/logger.dart';
import 'package:common/util/misc.dart';
import 'package:dio/dio.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_spinkit/flutter_spinkit.dart';
import 'package:gap/gap.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:progress_indicators/progress_indicators.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'package:mobileraker/ui/components/webcam/webcam_mjpeg.dart';

part 'webcam_ip_stream.g.dart';

/// The concrete stream flavor behind a `service: ipstream` webcam entry.
enum IpStreamKind { mjpeg, video }

/// Renders a Moonraker `ipstream` webcam ("IP camera" in Mainsail/Fluidd).
///
/// The type only guarantees "point your renderer at [WebcamInfo.streamUrl]" - what the URL
/// actually serves is up to the camera/software behind it (mjpeg-streamer style MJPEG for many
/// IP cams, or an MP4/HLS stream e.g. from go2rtc or camera-streamer). The response Content-Type
/// is probed once to route each case to the matching renderer: MJPEG goes to the existing
/// [WebcamMjpeg] pipeline, video containers are played with the platform video player
/// (ExoPlayer/AVPlayer), mirroring how the Fluidd web UI renders `ipstream` via a native
/// `<video autoplay muted playsinline>` element.
class WebcamIpStream extends ConsumerWidget {
  const WebcamIpStream({
    super.key,
    required this.webcamInfo,
    required this.machine,
    this.stackChild = const [],
    this.imageBuilder,
    this.onHidePressed,
  });

  final WebcamInfo webcamInfo;
  final Machine machine;
  final List<Widget> stackChild;
  final Widget Function(BuildContext context, Widget image)? imageBuilder;
  final VoidCallback? onHidePressed;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    var dio = ref.watch(dioClientProvider(machine.uuid));
    var clientType = ref.watch(jrpcClientTypeProvider(machine.uuid));
    var streamUri = resolveIpStreamUri(machine, clientType, webcamInfo.streamUrl);

    var kind = ref.watch(ipStreamKindResolverProvider(dio, streamUri));

    return kind.when(
      loading: () => _ConnectingWidget(),
      error: (error, _) => _ErrorWidget(
        streamUri: streamUri,
        error: error,
        onHidePressed: onHidePressed,
      ),
      data: (streamKind) => switch (streamKind) {
        IpStreamKind.mjpeg => WebcamMjpeg(
          key: ValueKey('${webcamInfo.uid ?? webcamInfo.name}#${machine.uuid}'),
          machine: machine,
          webcamInfo: webcamInfo,
          imageBuilder: imageBuilder,
          stackChild: stackChild,
          onHidePressed: onHidePressed,
        ),
        IpStreamKind.video => WebcamVideoStream(
          key: ValueKey('${webcamInfo.uid ?? webcamInfo.name}#${machine.uuid}'),
          streamUri: streamUri,
          httpHeaders: dio.options.headers.cast<String, String>(),
          rotation: webcamInfo.rotation,
          transformation: webcamInfo.transformMatrix,
          stackChild: stackChild,
          onHidePressed: onHidePressed,
        ),
      },
    );
  }
}

/// Resolves [camUri] against the connection currently used for [machine], mirroring the
/// resolution done in [WebcamMjpeg] for relative `/webcam/?action=...` style URLs.
Uri resolveIpStreamUri(Machine machine, ClientType clientType, Uri camUri) {
  var machineUri = machine.httpUri;
  return switch (clientType) {
    ClientType.octo => buildRemoteWebCamUri(
      machine.octoEverywhere!.uri,
      machineUri,
      camUri,
      allowCamPort: false,
    ),
    ClientType.manual => buildRemoteWebCamUri(machine.remoteInterface!.remoteUri, machineUri, camUri),
    _ => buildWebCamUri(machineUri, camUri),
  };
}

@riverpod
class IpStreamKindResolver extends _$IpStreamKindResolver {
  @override
  FutureOr<IpStreamKind> build(Dio dio, Uri uri) async {
    // A definitive file extension needs no network probe (and probing a live video stream
    // with an extra request is wasteful anyway).
    if (_kindFromUri(uri) case final kind?) return kind;

    final cancelToken = CancelToken();
    try {
      Response response;
      try {
        response = await dio.head(uri.toString(), cancelToken: cancelToken);
      } on DioException {
        // Some camera servers reject HEAD; a streamed GET completes once headers arrive.
        response = await dio.get(
          uri.toString(),
          options: Options(
            responseType: ResponseType.stream,
            receiveTimeout: const Duration(seconds: 10),
          ),
          cancelToken: cancelToken,
        );
      }

      final contentType = response.headers.value(HttpHeaders.contentTypeHeader)?.toLowerCase() ?? '';
      // Don't keep the live stream body open just because we peeked at its headers.
      cancelToken.cancel('content-type probe done');

      if (_kindFromContentType(contentType) case final kind?) return kind;
      talker.warning('IpStream probe got an ambiguous Content-Type "$contentType", assuming video');
      return IpStreamKind.video;
    } on Exception catch (e) {
      if (cancelToken.isCancelled) rethrow;
      talker.warning('IpStream content-type probe failed, falling back to URI heuristics', e);
      final kind = _kindFromUri(uri);
      return kind ?? IpStreamKind.video;
    }
  }
}

IpStreamKind? _kindFromUri(Uri uri) {
  final path = uri.path.toLowerCase();
  final query = uri.query.toLowerCase();
  // mjpeg-streamer style endpoints (/webcam/?action=stream, ustreamer, motion)
  if (query.contains('action=stream')) return IpStreamKind.mjpeg;
  if (path.endsWith('.m3u8') || path.endsWith('.mp4') || path.endsWith('.mpd') || path.endsWith('.mkv') || path.endsWith('.webm'))
    return IpStreamKind.video;
  if (path.endsWith('.mjpg') || path.endsWith('.mjpeg')) return IpStreamKind.mjpeg;
  return null;
}

IpStreamKind? _kindFromContentType(String contentType) {
  if (contentType.contains('multipart/x-mixed-replace') ||
      contentType.contains('image/jpeg') ||
      contentType.contains('image/jpg'))
    return IpStreamKind.mjpeg;
  if (contentType.startsWith('video/') ||
      contentType.contains('application/mp4') ||
      contentType.contains('mpegurl') ||
      contentType.contains('m3u8'))
    return IpStreamKind.video;
  return null;
}

/// Plays a live HTTP video stream (progressive/fragmented MP4, HLS, ...) through libmpv.
///
/// Deliberately NOT the platform player ([video_player] -> ExoPlayer on Android): Moonraker
/// `ipstream` entries frequently point at relayed live progressive MP4 (mp4mux/ffmpeg relays
/// serving `moov`-first, unbounded, duration-0 files over HTTP/1.0 with no `Range` support).
/// ExoPlayer treats that shape as a seekable file: it probes, mis-reads the (zero/rolling)
/// duration, then stalls seeking on a server that cannot honor byte ranges - the player
/// "initializes" but never renders frames. mpv is built for exactly this shape, matching the
/// browser `<video>` element Fluidd/Mainsail use for the same URL.
class WebcamVideoStream extends ConsumerStatefulWidget {
  const WebcamVideoStream({
    super.key,
    required this.streamUri,
    required this.httpHeaders,
    this.rotation = 0,
    this.transformation,
    this.stackChild = const [],
    this.onHidePressed,
  });

  final Uri streamUri;
  final Map<String, String> httpHeaders;
  final int rotation;
  final Matrix4? transformation;
  final List<Widget> stackChild;
  final VoidCallback? onHidePressed;

  @override
  ConsumerState<WebcamVideoStream> createState() => _WebcamVideoStreamState();
}

class _WebcamVideoStreamState extends ConsumerState<WebcamVideoStream> with WidgetsBindingObserver {
  static const _openTimeout = Duration(seconds: 15);
  static const _retryDelay = Duration(seconds: 10);

  Player? _player;
  VideoController? _controller;
  StreamSubscription<String>? _errorSub;
  StreamSubscription<VideoParams>? _openedSub;
  StreamSubscription<bool>? _completedSub;
  Timer? _openTimer;
  Timer? _retryTimer;
  Object? _initError;
  bool _connecting = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initPlayer();
  }

  void _disposePlayer() {
    _openTimer?.cancel();
    _errorSub?.cancel();
    _openedSub?.cancel();
    _completedSub?.cancel();
    _player?.dispose();
    _player = null;
    _controller = null;
  }

  void _fail(Object error) {
    if (!mounted) return;
    talker.warning('Could not play IpStream video stream ${widget.streamUri.path}', error);
    setState(() {
      _connecting = false;
      _initError = error;
    });
    _retryTimer = Timer(_retryDelay, _initPlayer);
  }

  void _initPlayer() {
    _retryTimer?.cancel();
    _disposePlayer();
    setState(() {
      _connecting = true;
      _initError = null;
    });

    MediaKit.ensureInitialized();
    final player = Player(
      configuration: const PlayerConfiguration(
        muted: true,
        title: 'Mobileraker webcam',
      ),
    );
    _player = player;
    _controller = VideoController(player);

    _errorSub = player.stream.error.listen((message) {
      if (message.isNotEmpty) _fail(message);
    });
    _openedSub = player.stream.videoParams.listen((params) {
      if (params != null && mounted) setState(() => _connecting = false);
    });
    // The relay dying mid-feed shows up as EOF: treat it like a dropped MJPEG stream and
    // reconnect so the card recovers without a page reload.
    _completedSub = player.stream.completed.listen((completed) {
      if (!completed || !mounted) return;
      _connecting = true;
      setState(() {});
      _retryTimer = Timer(const Duration(seconds: 3), _initPlayer);
    });
    _openTimer = Timer(_openTimeout, () {
      if (_connecting && mounted) _fail('No stream data within ${_openTimeout.inSeconds}s');
    });

    unawaited(_openStream(player));
  }

  /// Opens [player]'s media after applying mpv options the live `ipstream` shape needs.
  ///
  /// These relays answer with HTTP/1.0, no `Content-Length` and no `Range` support, so mpv marks
  /// the connection unseekable and the MP4 demuxer's probe-seek aborts parsing with
  /// "You can force it with '--force-seekable=yes'". Allowing forced seekability makes mpv emulate
  /// seeks by re-opening and reading forward - for a live tail that means just resuming the feed.
  /// Setting the option before [Player.open] matters: it must apply to the upcoming demux.
  Future<void> _openStream(Player player) async {
    final platform = player.platform;
    if (platform is NativePlayer) {
      try {
        await platform.setProperty('force-seekable', 'yes');
      } on Exception catch (setPropertyError) {
        try {
          await platform.command(['o', 'force-seekable', 'yes']);
        } on Exception catch (commandError) {
          talker.warning(
            'Could not set mpv force-seekable for IpStream webcam',
            '$setPropertyError / $commandError',
          );
        }
      }
    }

    if (!mounted || !identical(_player, player)) {
      // Widget was disposed or the player re-created while mpv was initializing.
      return;
    }
    await player.open(
      Media(widget.streamUri.toString(), httpHeaders: widget.httpHeaders),
      play: true,
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    var player = _player;
    if (player == null) return;
    switch (state) {
      case AppLifecycleState.resumed:
        player.play();
        break;
      case AppLifecycleState.inactive:
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        player.pause();
        break;
      default:
        break;
    }
  }

  @override
  void dispose() {
    _retryTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _disposePlayer();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    var controller = _controller;
    if (_initError != null) {
      return _ErrorWidget(
        streamUri: widget.streamUri,
        error: _initError,
        onRetryPressed: _initPlayer,
        onHidePressed: widget.onHidePressed,
      );
    }
    if (controller == null || _connecting) {
      return _ConnectingWidget();
    }

    Widget video = Video(
      controller: controller,
      controls: NoVideoControls,
    );
    if (widget.transformation != null) {
      video = Transform(
        alignment: Alignment.center,
        transform: widget.transformation!,
        child: video,
      );
    }
    if (widget.rotation != 0) {
      video = RotatedBox(
        quarterTurns: 1 * widget.rotation ~/ 90,
        child: video,
      );
    }

    return Stack(
      children: [
        video,
        ...widget.stackChild,
      ],
    );
  }
}

class _ConnectingWidget extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        SpinKitDancingSquare(
          color: Theme.of(context).colorScheme.secondary,
        ),
        const SizedBox(height: 15),
        FadingText(tr('components.connection_watcher.trying_connect')),
        Gap(8),
      ],
    );
  }
}

class _ErrorWidget extends StatelessWidget {
  const _ErrorWidget({
    super.key,
    required this.streamUri,
    this.error,
    this.onRetryPressed,
    this.onHidePressed,
  });

  final Uri streamUri;
  final Object? error;
  final VoidCallback? onRetryPressed;
  final VoidCallback? onHidePressed;

  @override
  Widget build(BuildContext context) {
    var themeData = Theme.of(context);
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Icon(Icons.error_outline),
        const SizedBox(height: 30),
        const Text('pages.dashboard.general.cam_card.error_connecting', textAlign: TextAlign.center)
            .tr(args: [streamUri.obfuscate().toString()]),
        Wrap(
          spacing: 4,
          alignment: WrapAlignment.spaceEvenly,
          children: [
            if (onHidePressed != null)
              TextButton.icon(
                onPressed: onHidePressed,
                icon: const Icon(Icons.visibility_off),
                label: const Text('general.hide').tr(),
              ),
            if (onRetryPressed != null)
              TextButton.icon(
                onPressed: onRetryPressed,
                icon: const Icon(Icons.restart_alt_outlined),
                label: const Text('components.connection_watcher.reconnect').tr(),
              ),
          ],
        ),
        const Divider(),
        Text.rich(
          TextSpan(
            text: 'IpStream streamURI:\n${streamUri.obfuscate()}\n',
            children: [
              TextSpan(text: '\nError Details:\n', style: themeData.textTheme.bodySmall),
              TextSpan(
                text: error.toString(),
                style: themeData.textTheme.bodySmall?.copyWith(color: themeData.colorScheme.error),
              ),
            ],
          ),
          style: themeData.textTheme.bodySmall,
          textAlign: TextAlign.justify,
        ),
        Gap(8),
      ],
    );
  }
}
