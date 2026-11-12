import 'package:flutter/widgets.dart';
import 'package:livekit_client/livekit_client.dart';

// =======================================================
// สื่อของสาย (เสียง/วิดีโอ) — แยกจากหน้าโทร เพื่อทดสอบหน้าโทรได้โดยไม่ต่อ LiveKit จริง
// LiveKit Cloud จัดการ STUN/TURN (เชื่อมต่อข้ามเครือข่ายได้) / ไม่มีการบันทึกเสียงหรือวิดีโอ
// =======================================================

abstract class CallMedia {
  // อีกฝ่ายเข้าห้องแล้ว (เริ่มนับเวลาสาย)
  VoidCallback? onRemoteJoined;

  // อีกฝ่ายออกจากห้อง
  VoidCallback? onRemoteLeft;

  // หลุดจากห้อง (เน็ตหลุดเกินกู้คืน / เซิร์ฟเวอร์ลบห้อง)
  VoidCallback? onDisconnected;

  // กำลังเชื่อมต่อใหม่ (true) / กลับมาแล้ว (false)
  ValueChanged<bool>? onReconnecting;

  // วิดีโอเปลี่ยน → วาดหน้าใหม่
  VoidCallback? onTracksChanged;

  bool get remotePresent;

  Future<void> connect(String url, String token, {required bool video});

  Future<void> setMicrophone(bool on);

  Future<void> setCamera(bool on);

  Future<void> switchCamera();

  Future<void> setSpeaker(bool on);

  Widget? localVideo();

  Widget? remoteVideo();

  Future<void> disconnect();
}

class LiveKitCallMedia extends CallMedia {
  Room? _room;
  EventsListener<RoomEvent>? _listener;
  CameraPosition _position = CameraPosition.front;
  bool _closing = false;

  @override
  bool get remotePresent => _room?.remoteParticipants.isNotEmpty ?? false;

  @override
  Future<void> connect(String url, String token, {required bool video}) async {
    final Room room = Room(
      roomOptions: const RoomOptions(adaptiveStream: true, dynacast: true),
    );
    final EventsListener<RoomEvent> listener = room.createListener();

    _room = room;
    _listener = listener;

    listener
      ..on<ParticipantConnectedEvent>((_) => onRemoteJoined?.call())
      ..on<ParticipantDisconnectedEvent>((_) {
        if (room.remoteParticipants.isEmpty) onRemoteLeft?.call();
      })
      ..on<TrackSubscribedEvent>((_) => onTracksChanged?.call())
      ..on<TrackUnsubscribedEvent>((_) => onTracksChanged?.call())
      ..on<LocalTrackPublishedEvent>((_) => onTracksChanged?.call())
      ..on<RoomReconnectingEvent>((_) => onReconnecting?.call(true))
      ..on<RoomReconnectedEvent>((_) => onReconnecting?.call(false))
      ..on<RoomDisconnectedEvent>((_) {
        if (!_closing) onDisconnected?.call();
      });

    await room.connect(url, token);
    await room.localParticipant?.setMicrophoneEnabled(true);

    if (video) await room.localParticipant?.setCameraEnabled(true);

    if (room.remoteParticipants.isNotEmpty) onRemoteJoined?.call();

    onTracksChanged?.call();
  }

  @override
  Future<void> setMicrophone(bool on) async {
    await _room?.localParticipant?.setMicrophoneEnabled(on);
  }

  @override
  Future<void> setCamera(bool on) async {
    await _room?.localParticipant?.setCameraEnabled(on);
    onTracksChanged?.call();
  }

  @override
  Future<void> switchCamera() async {
    _position = _position == CameraPosition.front
        ? CameraPosition.back
        : CameraPosition.front;

    await _localVideoTrack?.setCameraPosition(_position);
    onTracksChanged?.call();
  }

  @override
  Future<void> setSpeaker(bool on) =>
      AudioManager.instance.setSpeakerOutputPreferred(on, force: on);

  LocalVideoTrack? get _localVideoTrack {
    for (final publication
        in _room?.localParticipant?.videoTrackPublications ??
            const <LocalTrackPublication>[]) {
      final Track? track = publication.track;

      if (track is LocalVideoTrack && !publication.muted) return track;
    }

    return null;
  }

  VideoTrack? get _remoteVideoTrack {
    for (final participant
        in _room?.remoteParticipants.values ?? const <RemoteParticipant>[]) {
      for (final publication in participant.videoTrackPublications) {
        final VideoTrack? track = publication.track;

        if (track != null && !publication.muted) return track;
      }
    }

    return null;
  }

  @override
  Widget? localVideo() {
    final LocalVideoTrack? track = _localVideoTrack;

    return track == null
        ? null
        : VideoTrackRenderer(
            track,
            fit: VideoViewFit.cover,
            mirrorMode: _position == CameraPosition.front
                ? VideoViewMirrorMode.mirror
                : VideoViewMirrorMode.off,
          );
  }

  @override
  Widget? remoteVideo() {
    final VideoTrack? track = _remoteVideoTrack;

    return track == null
        ? null
        : VideoTrackRenderer(track, fit: VideoViewFit.cover);
  }

  @override
  Future<void> disconnect() async {
    _closing = true;

    final Room? room = _room;
    _room = null;

    await _listener?.dispose();
    _listener = null;

    if (room != null) {
      await room.disconnect();
      await room.dispose();
    }
  }
}
