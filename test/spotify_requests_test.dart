import 'dart:convert' show jsonDecode;
import 'dart:io' show File;

import 'package:convert/convert.dart' show hex;
import 'package:flutter_test/flutter_test.dart';
import 'package:spotify_flutter/protocol/generated/extended_metadata.pb.dart' as metadata;
import 'package:spotify_flutter/protocol/generated/extension_kind.pbenum.dart';
import 'package:spotify_flutter/playback/spotify_requests.dart';
import 'package:spotify_flutter/playback/native_playback_id.dart';
import 'package:spotify_flutter/protocol/native_http_defaults.dart';

void main() {
  const defaults = NativeHttpDefaults(userAgent: 'Spotify/independent-offline-fixture');
  SpotifyRequests requests() => SpotifyRequests(baseUrl: 'https://spclient.example.test:443/',
    inheritedHeaders: const {'Authorization': 'Bearer synthetic-access-token',
      'client-token': 'synthetic-client-token'}, defaults: defaults);

  test('REA native media fields and original protobuf bytes reach the request envelope', () {
    final factory = requests();
    final body = metadata.BatchedEntityRequest(
      header: metadata.BatchedEntityRequestHeader(country: 'SE', catalogue: 'free', taskId: [0, 255]),
      entityRequest: [metadata.EntityRequest(entityUri: 'spotify:track:0000000000000000000001', query: [
        metadata.ExtensionQuery(extensionKind: ExtensionKind.TRACK_V4, etag: '%7E'),
        metadata.ExtensionQuery(extensionKind: ExtensionKind.UNKNOWN_EXTENSION, etag: ''),
      ]), metadata.EntityRequest(entityUri: 'spotify:episode:0000000000000000000002', query: [
        metadata.ExtensionQuery(extensionKind: ExtensionKind.EPISODE_V4),
      ])]);
    final planned = factory.extendedMetadata(body);
    expect(planned.method, 'POST');
    expect(planned.url, 'https://spclient.example.test:443/extended-metadata/v0/extended-metadata');
    expect(planned.headers, {'Authorization': 'Bearer synthetic-access-token', 'client-token': 'synthetic-client-token',
      'Content-Type': 'application/protobuf', 'Accept': 'application/protobuf', 'User-Agent': defaults.userAgent});
    // Independent Google protoc36.2 --encode=spotify.extendedmetadata.BatchedEntityRequest
    // against the pinned reference schema. The input is the text-format version
    // of the populated request above, including the explicit default query.
    expect(planned.body, hex.decode('0a0e0a0253451204667265651a0200ff12310a2473706f746966793a747261636b3a303030303030303030303030303030303030303030311207080a12032537451200122c0a2673706f746966793a657069736f64653a303030303030303030303030303030303030303030321202080c'));
    final explicitDefaults = metadata.BatchedEntityRequest(
      header: metadata.BatchedEntityRequestHeader(country: '', catalogue: '', taskId: []),
      entityRequest: [metadata.EntityRequest(entityUri: '', query: [
        metadata.ExtensionQuery(extensionKind: ExtensionKind.UNKNOWN_EXTENSION, etag: ''),
      ])]);
    // The same independent C++ protoc invocation with explicitly empty fields
    // retains empty header/entity/query messages while omitting default scalars.
    expect(factory.extendedMetadata(explicitDefaults).body, hex.decode('0a0012021200'));
    expect(explicitDefaults.header.hasCountry(), isTrue);
    expect(explicitDefaults.entityRequest.single.query.single.hasExtensionKind(), isTrue);

    final storage = factory.storageResolve(List.generate(20, (i) => i), storageMode: 0, audioFormat: 42);
    expect(storage.method, 'GET');
    expect(storage.url, 'https://spclient.example.test:443/storage-resolve/v2/files/audio/interactive/42/000102030405060708090a0b0c0d0e0f10111213?product=0');
    expect(storage.body, isEmpty);
    expect(storage.headers, {'Authorization': 'Bearer synthetic-access-token',
      'client-token': 'synthetic-client-token', 'cache-control': 'no-cache', 'User-Agent': defaults.userAgent});
    // REA 0x100762a5c selects offline for1, prefetch for2 and interactive otherwise.
    // Native 0x100780440 appends signed int32 format and raw partner bytes.
    for (final mode in [(1, 'offline'), (2, 'interactive_prefetch'), (-1, 'interactive'), (3, 'interactive')]) {
      expect(factory.storageResolve(List.filled(20, 0), storageMode: mode.$1, audioFormat: -7,
        partner: 'brand%2fuk&x=%7E').url,
        'https://spclient.example.test:443/storage-resolve/v2/files/audio/${mode.$2}/-7/${'00' * 20}?product=0&partner=brand%2fuk&x=%7E');
    }

    final inherited = SpotifyRequests(baseUrl: 'https://spclient.example.test',
      inheritedHeaders: const {'content-type': '', 'ACCEPT': '', 'User-Agent': ''}, defaults: defaults)
      .extendedMetadata(metadata.BatchedEntityRequest());
    expect(inherited.headers, {'content-type': 'application/protobuf',
      'ACCEPT': 'application/protobuf', 'User-Agent': ''});
  });

  test('Original native CDN outgoing request fields match unchanged owner execution', () {
    final fixture = jsonDecode(File('reverse-engineering/fixtures/native-cdn-requests.json').readAsStringSync()) as Map<String, dynamic>;
    final idFixture = jsonDecode(File('reverse-engineering/fixtures/native-playback-id.json').readAsStringSync()) as Map<String, dynamic>;
    final factory = requests();
    final cases = [
      for (final input in (fixture['cases'] as List).cast<Map<String, dynamic>>())
        (input, input['playbackIdHex'] == null ? null : hex.decode(input['playbackIdHex'] as String)),
      // Independent original constructor selection + generator output goes
      // through the complete original CDN HTTP owner before fixture capture.
      for (final input in (idFixture['cases'] as List).cast<Map<String, dynamic>>())
        (input, NativePlaybackId(
          given: input['givenIdHex'] == null ? null : hex.decode(input['givenIdHex'] as String),
          entropy: (_) => hex.decode(input['entropyHex'] as String)).bytes),
    ];
    for (final (input, playbackId) in cases) {
      final original = input['request'] as Map<String, dynamic>;
      final cdn = factory.signedCdnRange(signedUrl: input['signedUrl'] as String,
        firstByte: input['firstByte'] as int, lastByte: input['lastByte'] as int,
        playbackId16: playbackId,
        segmentTimestampMilliseconds: input['segmentTimestampMilliseconds'] as int?);
      expect(cdn.method, original['method'], reason: input['name'] as String);
      expect(cdn.url, original['url'], reason: input['name'] as String);
      expect(cdn.headers, {...original['headers'] as Map<String, dynamic>, 'User-Agent': defaults.userAgent},
        reason: input['name'] as String);
      expect(cdn.body, hex.decode(original['bodyHex'] as String));
      expect(cdn.authorize, isFalse);
      expect(cdn.includeCredentials, isFalse);
      expect(cdn.responseType, 'bytes');
    }
  });

  test('Invalid identities, raw targets, file IDs and inclusive ranges fail before any envelope is returned', () {
    for (final origin in ['http://host.test', 'https://user@host.test', 'https://host.test/path', 'https://host.test?query', 'https://host.test#']) {
      expect(() => SpotifyRequests(baseUrl: origin, inheritedHeaders: const {}, defaults: defaults), throwsArgumentError);
    }
    for (final identity in ['bad\r\nheader', 'bad\u0000header']) {
      expect(() => SpotifyRequests(baseUrl: 'https://host.test', inheritedHeaders: {'Authorization': identity}, defaults: defaults), throwsArgumentError);
    }
    expect(() => SpotifyRequests(baseUrl: 'https://host.test', inheritedHeaders: const {},
      defaults: const NativeHttpDefaults(userAgent: '')), throwsArgumentError);
    final factory = requests();
    for (final id in [List.filled(19, 0), List.filled(21, 0), [256, ...List.filled(19, 0)]]) {
      expect(() => factory.storageResolve(id, storageMode: 0, audioFormat: 0), throwsArgumentError);
    }
    for (final range in [(-1, 0), (9, 8)]) {
      expect(() => factory.signedCdnRange(signedUrl: 'https://cdn.test/file', firstByte: range.$1, lastByte: range.$2), throwsRangeError);
    }
    expect(() => factory.signedCdnRange(signedUrl: 'https://user@cdn.test/file', firstByte: 0, lastByte: 0), throwsArgumentError);
  });
}
