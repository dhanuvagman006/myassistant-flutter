import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:simli_client/simli_client.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:simli_client/models/simli_client_config.dart';
import 'package:logging/logging.dart';
import '../../../services/live_service.dart';
import '../../../design/neon_tokens.dart';

class AvatarView extends StatefulWidget {
  final String apiKey;
  final String faceId;
  final bool isLive;

  const AvatarView({
    super.key,
    required this.apiKey,
    required this.faceId,
    required this.isLive,
  });

  @override
  State<AvatarView> createState() => _AvatarViewState();
}

class _AvatarViewState extends State<AvatarView> {
  SimliClient? _simliClient;
  bool _isConnected = false;
  bool _isConnecting = false;
  // Bug fix #9: guard against re-triggering init on every rebuild after a failure
  bool _initFailed = false;

  @override
  void initState() {
    super.initState();
    if (widget.isLive) _initSimli();
  }

  @override
  void didUpdateWidget(covariant AvatarView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isLive && !oldWidget.isLive && !_initFailed) {
      _initSimli();
    } else if (!widget.isLive && oldWidget.isLive) {
      _cleanupSimli();
    }
  }

  Future<void> _initSimli() async {
    // Guard: already initialised or currently connecting
    if (_simliClient != null || _isConnecting) return;

    if (mounted) setState(() => _isConnecting = true);

    final config = SimliClientConfig(
      apiKey: widget.apiKey,
      faceId: widget.faceId,
      handleSilence: true,
      maxSessionLength: 3600, // 1 hour max
      maxIdleTime: 60,        // 60s idle timeout
      syncAudio: true,
      iceGatheringTimeout: const Duration(seconds: 30),
    );

    _simliClient = SimliClient(
      clientConfig: config,
      log: Logger('SimliClient'),
    );

    // Bug fix #3: wire up audio callback BEFORE awaiting start(),
    // so no audio chunks are dropped during the connection phase.
    LiveService.instance.onAudioChunk = (Uint8List chunk) {
      if (_isConnected) {
        _simliClient?.sendAudioData(chunk);
      }
    };

    _simliClient!.onConnection = () {
      if (mounted) setState(() { _isConnected = true; _isConnecting = false; });
    };

    _simliClient!.onDisconnected = () {
      if (mounted) setState(() { _isConnected = false; _isConnecting = false; });
    };

    _simliClient!.onFailed = (err) {
      debugPrint('Simli connection failed: [${err.errorCode}] ${err.message}');
      _initFailed = true;
      if (mounted) setState(() { _isConnected = false; _isConnecting = false; });
    };

    try {
      await _simliClient!.start();
    } catch (e) {
      debugPrint('SimliClient.start() threw: $e');
      _initFailed = true;
      if (mounted) setState(() { _isConnected = false; _isConnecting = false; });
    }
  }

  Future<void> _cleanupSimli() async {
    // Unhook the audio callback immediately so no more frames are forwarded
    LiveService.instance.onAudioChunk = null;

    final client = _simliClient;
    _simliClient = null; // null out before await so no double-close
    _initFailed = false;  // allow re-init if the widget comes back live

    if (client != null) {
      try {
        await client.close();
      } catch (e) {
        debugPrint('SimliClient.close() error: $e');
      }
    }

    if (mounted) {
      setState(() {
        _isConnected = false;
        _isConnecting = false;
      });
    }
  }

  @override
  void dispose() {
    // Fire-and-forget cleanup — dispose() must be synchronous
    LiveService.instance.onAudioChunk = null;
    final client = _simliClient;
    _simliClient = null;
    if (client != null) {
      client.close().catchError((e) => debugPrint('Simli dispose close error: $e'));
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Neon.cyan.withValues(alpha: 0.15),
            blurRadius: 20,
            spreadRadius: 2,
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        alignment: Alignment.center,
        fit: StackFit.expand,
        children: [
          if (_isConnected && _simliClient?.videoRenderer != null)
            RTCVideoView(
              _simliClient!.videoRenderer!,
              objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
            )
          else if (_isConnecting)
            const Center(child: CircularProgressIndicator(color: Neon.cyan))
          else if (_initFailed)
            // Failed state: show message instead of looping
            const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.warning_amber_rounded, color: Colors.orange, size: 48),
                  SizedBox(height: 12),
                  Text('Avatar unavailable', style: TextStyle(color: Colors.white60, fontSize: 14)),
                ],
              ),
            )
          else
            // Idle / not yet live
            Container(
              color: Colors.black,
              child: const Icon(Icons.person_outline, size: 80, color: Colors.white24),
            ),
        ],
      ),
    );
  }
}
