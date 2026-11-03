import 'package:cancellation_token/cancellation_token.dart';

import 'dart:convert';

import 'package:fixnum/fixnum.dart';
import 'package:protobuf/protobuf.dart';

import '../protocol/esperanto.dart';
import '../protocol/pathfinder.dart';
import '../protocol/generated/playlist_get_request.pb.dart';
import 'models.dart';
import 'playlist_dates.dart';
import 'playlist_policy.dart';
import 'wire_order.dart';

part 'album_projection.dart';
part 'playlist_projection.dart';

abstract interface class EntityRepository {
  Future<EntityPage> open(String uri, {CancellationToken? cancellationToken});
  Future<EntityTrackPage> tracks(EntityDetails details, {required int offset, int? limit, CancellationToken? cancellationToken});
}

/// Recovered online album and native playlist read paths. Dependencies are inert
/// until the caller explicitly installs a sender or a local service handler.
class DesktopEntityRepository implements EntityRepository {
  const DesktopEntityRepository(this.loader, {required this.dispatcher,
    this.albumLocale = '', this.features = const EntityFeatures()});
  final PathfinderLoader loader;
  final EsperantoDispatcher dispatcher;
  final String albumLocale;
  final EntityFeatures features;
  static const playlistService = 'spotify.playlist_esperanto.proto.PlaylistDataService';
  static const albumOperation = PathfinderOperation(name: 'getAlbum', operation: 'query',
    sha256Hash: '11c9cad9cb24c4f9e25ef9456f68621cfd6006a90f679e729c1d2f2fd70dfe16', value: null);
  static const albumTracksOperation = PathfinderOperation(name: 'queryAlbumTracks', operation: 'query',
    sha256Hash: '11c9cad9cb24c4f9e25ef9456f68621cfd6006a90f679e729c1d2f2fd70dfe16', value: null);

  @override
  Future<EntityPage> open(String uri, {CancellationToken? cancellationToken}) async {
    cancellationToken?.throwIfCancelled();
    if (uri.startsWith('spotify:album:')) {
      final body = await _query(albumOperation, {'uri': uri, 'locale': albumLocale, 'offset': 0, 'limit': 50},
        headers: const {'spotify-app-version': '896000000'}, cancellationToken: cancellationToken);
      final album = _map(_map(body['data'])['albumUnion']);
      if ({'GenericError', 'NotFound', 'RestrictedContent'}.contains(album['__typename'])) {
        throw const EntityQueryError({'message': ''});
      }
      if (album['__typename'] != 'Album') throw const EntityQueryError(null);
      return _albumPage(album, _map(_map(body['data'])['meV2'])['ianaTimezoneId'] as String?);
    }
    if (_playlistUri(uri)) {
      final response = await _playlist(uri, offset: 0, limit: 50, paging: false, cancellationToken: cancellationToken);
      return _playlistPage(response, uri);
    }
    throw const EntityQueryError({'message': 'This entity type is currently unavailable.'});
  }

  @override
  Future<EntityTrackPage> tracks(EntityDetails details, {required int offset, int? limit, CancellationToken? cancellationToken}) async {
    cancellationToken?.throwIfCancelled();
    if (details.type == 'album') {
      final count = limit ?? 300;
      final indices = <int>[];
      if (details.hasDiscRows) {
        for (final (index, value) in _list(details.discs['items']).indexed) {
          indices.add(index);
          indices.addAll(List.filled(_map(value)['nrTracks'] as int? ?? 0, index + 1));
        }
      }
      final nativeOffset = offset - (details.hasDiscRows ? indices.elementAtOrNull(offset) ?? 0 : 0);
      final body = await _query(albumTracksOperation, {'uri': details.uri, 'offset': nativeOffset, 'limit': count},
        cancellationToken: cancellationToken);
      final album = _map(_map(body['data'])['albumUnion']);
      if (album['__typename'] != 'Album') return EntityTrackPage(offset: offset, limit: count, totalLength: 0);
      final tracks = _map(album['tracksV2']);
      return EntityTrackPage(rows: _albumRows(tracks, details.discs), offset: offset, limit: count,
        totalLength: (tracks['totalCount'] as int? ?? 0) + (details.hasDiscRows ? details.discs['totalCount'] as int : 0));
    }
    if (details.type == 'playlist') {
      final response = await _playlist(details.uri, offset: offset, limit: limit ?? 50, paging: true,
        cancellationToken: cancellationToken);
      return _playlistRows(_map(response['data']));
    }
    throw const EntityQueryError({'message': 'This entity type is currently unavailable.'});
  }

  Future<EntityJson> _query(PathfinderOperation operation, EntityJson variables,
      {Map<String, String> headers = const {}, CancellationToken? cancellationToken}) async {
    final Object? response;
    try {
      response = await loader.load(operation, variables, headers: headers, cancellationToken: cancellationToken);
    } on CancelledException { rethrow; } catch (error) {
      final message = switch (error) {
        HttpResponseError() => error.message,
        GraphQLFallbackUnavailableError() => error.message,
        Error() => error.toString(), Exception() => error.toString(), _ => null,
      };
      throw EntityQueryError(message == null ? null : [{'message': message}]);
    }
    final body = _map(response);
    if (_truthy(body['errors'])) throw EntityQueryError(body['errors']);
    return body;
  }

  Future<EntityJson> _playlist(String uri, {required int offset, required int limit, required bool paging,
      CancellationToken? cancellationToken}) async {
    cancellationToken?.throwIfCancelled();
    final templates = jsonDecode(playlistPolicyJson) as Map<String, dynamic>;
    final policy = _map(templates['base']);
    if (paging) policy['playlist'] = templates['pagingPlaylist'];
    if (features.watchFeed) (_map(policy['playlist'])['extension'] as List).add('WATCH_FEED_ENTITY_EXPLORER');
    if (features.authors) (_map(policy['item'])['extensionPolicy'] as List).add({'linkType': 'SHOW', 'extension': 'IDENTITY_TRAIT'});
    if (features.ageAssurance) (_map(_map(policy['episode'])['episode'])['extension'] as List).add('CONSUMPTION_EXPERIENCE_TRAIT');
    final request = PlaylistGetRequest()..mergeFromProto3Json({
      'uri': uri, 'query': {'boolPredicates': ['NOT_RECOMMENDATION'],
        'range': {'start': offset, 'length': limit}, 'showUnavailable': true,
        'supportedPlaceholderTypes': ['SHOW', 'KALLAX', 'PODCAST_CHAPTER', 'CLIP']}, 'policy': policy,
    });
    _clearDefaults(request);
    try {
      final response = await dispatcher.callSingle(EsperantoCall(playlistService, 'Get', _originalBytes(request)),
        cancellationToken: cancellationToken);
      return _messageMap(PlaylistGetResponse.fromBuffer(response));
    } on CancelledException { rethrow; } on EntityQueryError { rethrow; } catch (error) {
      throw EntityQueryError({'message': error.toString()});
    }
  }
}

bool _playlistUri(String uri) => uri.startsWith('spotify:playlist:') ||
    RegExp(r'^spotify:user:[^:]*:playlist:').hasMatch(uri);
EntityJson _map(Object? value) => value is Map ? value.cast<String, Object?>() : {};
List<Object?> _list(Object? value) => value is List ? value : [];
String _str(Object? value) => value is String ? value : '';
bool _truthy(Object? value) => value != null && value != false && value != '' && value != 0;

void _clearDefaults(GeneratedMessage message) {
  for (final field in message.info_.fieldInfo.values) {
    final value = message.getField(field.tagNumber);
    if (value is GeneratedMessage && message.hasField(field.tagNumber)) {
      _clearDefaults(value);
    } else if (value is List) {
      for (final child in value.whereType<GeneratedMessage>()) { _clearDefaults(child); }
    } else if (!message.info_.oneofs.containsKey(field.tagNumber) &&
        (value == 0 || value == false || value == '' || value is ProtobufEnum && value.value == 0)) {
      message.clearField(field.tagNumber);
    }
  }
}

List<int> _originalBytes(GeneratedMessage message) {
  final writer = CodedBufferWriter();
  final fields = message.info_.fieldInfo;
  final order = entityWireFieldOrder[message.info_.qualifiedMessageName] ?? fields.keys;
  for (final number in order) {
    final field = fields[number]!;
    final value = message.getField(number);
    if (field.isRepeated) {
      if (value is List && value.isEmpty && field.type & PbFieldType.PACKED_BIT != 0) {
        writer.writeField(number, PbFieldType.OY, <int>[]);
      } else if (value is List && value.isNotEmpty && value.first is GeneratedMessage) {
        for (final child in value.cast<GeneratedMessage>()) { writer.writeField(number, PbFieldType.OY, _originalBytes(child)); }
      } else { writer.writeField(number, field.type, value); }
    } else if (message.hasField(number)) {
      writer.writeField(number, value is GeneratedMessage ? PbFieldType.OY : field.type,
        value is GeneratedMessage ? _originalBytes(value) : value);
    }
  }
  return writer.toBuffer();
}

EntityJson _messageMap(GeneratedMessage message) => {
  for (final field in message.info_.fieldInfo.values)
    if ((message.getField(field.tagNumber) is! GeneratedMessage || message.hasField(field.tagNumber)) &&
        (!message.info_.oneofs.containsKey(field.tagNumber) || message.hasField(field.tagNumber)))
      field.name: _messageValue(message.getField(field.tagNumber)),
};
Object? _messageValue(Object? value) => switch (value) {
  GeneratedMessage() => _messageMap(value), ProtobufEnum() => value.value,
  Int64() => value.toString(), List() => value.map(_messageValue).toList(), _ => value,
};
