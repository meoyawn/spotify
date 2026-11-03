import 'package:protobuf/protobuf.dart';

import '../protocol/esperanto.dart';
import '../protocol/generated/es_command_options.pb.dart';
import '../protocol/generated/es_context_player_error.pb.dart';
import '../protocol/generated/es_context_player_state.pb.dart';
import '../protocol/generated/es_get_error_request.pb.dart';
import '../protocol/generated/es_get_state_request.pb.dart';
import '../protocol/generated/es_logging_params.pb.dart';
import '../protocol/generated/es_pause.pb.dart';
import '../protocol/generated/es_pauseresume_origin.pb.dart';
import '../protocol/generated/es_play.pb.dart';
import '../protocol/generated/es_prepare_play.pb.dart';
import '../protocol/generated/es_response_with_reasons.pb.dart';
import '../protocol/generated/es_resume.pb.dart';
import '../protocol/generated/es_seek_to.pb.dart';
import '../protocol/generated/es_set_options.pb.dart';
import '../protocol/generated/es_set_shuffling_context.pb.dart';
import '../protocol/generated/es_skip_next.pb.dart';
import '../protocol/generated/es_skip_prev.pb.dart';
import 'requests.dart';

class PlaybackCommandException implements Exception {
  const PlaybackCommandException(this.code, this.reasons);
  final int code;
  final String reasons;
  String get message => "Command failed with code '$code' and reasons '$reasons'";
  @override
  String toString() => message;
}

/// Original ContextPlayer renderer boundary; dispatch is explicitly local.
class ContextPlayerClient {
  ContextPlayerClient(EsperantoDispatcher dispatcher, {int Function()? nowMilliseconds})
    : _client = EsperantoClient(serviceId, dispatcher),
      _now = nowMilliseconds ?? _currentTime;

  static const serviceId = 'spotify.player.esperanto.proto.ContextPlayer';
  final EsperantoClient _client;
  final int Function() _now;
  static int _currentTime() => DateTime.now().millisecondsSinceEpoch;

  LoggingParams _logging([PlaybackLogging? params]) => LoggingParams(
    commandInitiatedTime: optionalInt(_now()),
    interactionIds: nonempty(params?.interactionId) == null ? null : [params!.interactionId!],
    pageInstanceIds: nonempty(params?.pageInstanceId) == null ? null : [params!.pageInstanceId!],
    commandId: params?.commandId,
  );

  Future<void> _command(String method, GeneratedMessage request) async {
    final response = await _client.single(method, request, ResponseWithReasons.fromBuffer);
    final unknown = response.unknownFields.getField(1)?.varints;
    final code = unknown?.isNotEmpty == true ? unknown!.last.toSigned(32).toInt() : response.error.value;
    if (code != ResponseWithReasons_Error.OK.value &&
        !(code == ResponseWithReasons_Error.FORBIDDEN.value && response.reasons == 'already_paused')) {
      throw PlaybackCommandException(code, response.reasons);
    }
  }

  Future<void> play(PlaybackContext context, PlaybackOrigin origin,
      {PlaybackOptions options = const PlaybackOptions()}) => _command('Play', PlayRequest(
    preparePlayRequest: PreparePlayRequest(context: context.toMessage(),
      playOrigin: origin.toMessage(), options: options.toMessage(context)),
    loggingParams: _logging(options.loggingParams),
  ));

  Future<void> pause([PlaybackOrigin? origin]) => _command('Pause', PauseRequest(
    loggingParams: _logging(), pauseOrigin: origin == null ? null :
      PauseResumeOrigin(featureIdentifier: nonempty(origin.featureIdentifier)),
  ));

  Future<void> resume([PlaybackOrigin? origin]) => _command('Resume', ResumeRequest(
    loggingParams: _logging(), resumeOrigin: origin == null ? null :
      PauseResumeOrigin(featureIdentifier: nonempty(origin.featureIdentifier)),
  ));

  Future<void> skipNext() => _command('SkipNext', SkipNextRequest(loggingParams: _logging()));
  Future<void> skipTo(PlaybackItemReference track) => _command('SkipNext',
    SkipNextRequest(track: track.toMessage(), loggingParams: _logging()));
  Future<void> skipPrevious() => _command('SkipPrev',
    SkipPrevRequest(allowSeeking: true, loggingParams: _logging()));

  Future<void> seekTo(num milliseconds, {List<int>? onlyForPlaybackId}) =>
    _seek(milliseconds, false, onlyForPlaybackId);
  Future<void> seekBy(num milliseconds, {List<int>? onlyForPlaybackId}) =>
    _seek(milliseconds, true, onlyForPlaybackId);

  Future<void> _seek(num milliseconds, bool relative, List<int>? playbackId) {
    final position = milliseconds.floor();
    final request = SeekToRequest(options: CommandOptions(onlyForPlaybackId: playbackId),
      loggingParams: _logging(), position: position == 0 ? null : optionalInt(position).value,
      relative: relative ? SeekToRequest_Relative.CURRENT : null);
    return _command('SeekTo', request);
  }

  Future<void> setShuffle(bool enabled) => _command('SetShufflingContext',
    SetShufflingContextRequest(shufflingContext: enabled ? true : null, loggingParams: _logging()));
  Future<void> setRepeat(PlaybackRepeat repeat) => _command('SetOptions', SetOptionsRequest(
    repeatingTrack: optionalBool(repeat == PlaybackRepeat.track),
    repeatingContext: optionalBool(repeat != PlaybackRepeat.none), loggingParams: _logging(),
  ));
  Future<void> setSpeed(double speed) => _command('SetOptions',
    SetOptionsRequest(playbackSpeed: speed, loggingParams: _logging()));

  Stream<ContextPlayerState> watchState({int previousTracks = 1, int nextTracks = 50}) =>
    _client.streaming('GetState', GetStateRequest(prevTracksCap: optionalInt(previousTracks),
      nextTracksCap: optionalInt(nextTracks)), ContextPlayerState.fromBuffer);
  Stream<ContextPlayerError> watchErrors() =>
    _client.streaming('GetError', GetErrorRequest(), ContextPlayerError.fromBuffer);
}
