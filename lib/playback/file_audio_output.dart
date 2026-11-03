import 'audio_source.dart';

class PcmAudioOutputItem {
  const PcmAudioOutputItem({required this.id, required this.path, this.source});
  final int id;
  final String path;
  final PreparedAudioFile? source;
}

class PcmAudioOutputEvent {
  const PcmAudioOutputEvent({this.id, required this.type,
    this.position, this.duration, this.error});
  final int? id;
  final String type;
  final Duration? position, duration;
  final Object? error;
}
