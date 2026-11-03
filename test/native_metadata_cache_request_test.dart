import 'dart:convert';
import 'dart:io';

import 'package:convert/convert.dart' show hex;
import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:protobuf/well_known_types/google/protobuf/any.pb.dart';
import 'package:spotify_flutter/library/native_metadata_client.dart';
import 'package:spotify_flutter/playback/spotify_requests.dart';
import 'package:spotify_flutter/protocol/generated/entity_extension_data.pb.dart';
import 'package:spotify_flutter/protocol/generated/extended_metadata.pb.dart';
import 'package:spotify_flutter/protocol/generated/extension_kind.pbenum.dart';
import 'package:spotify_flutter/protocol/generated/metadata.pb.dart' as v4;
import 'package:spotify_flutter/protocol/native_http_defaults.dart';
import 'package:spotify_flutter/protocol/request_builder.dart';

void main() {
  test('Original metadata freshness boundaries govern actual Library HTTP batches', () async {
    final original = jsonDecode(File('reverse-engineering/fixtures/native-library-metadata.json')
      .readAsStringSync()) as Map;
    final input = (original['cases'] as List).first as Map;
    final uris = (input['uris'] as List).cast<String>();
    final expected = input['request'] as Map;
    final policy = jsonDecode(File('reverse-engineering/evidence/native-audio-files-cache.json')
      .readAsStringSync()) as Map;
    final boundaries = (policy['admissionCases'] as List).take(3);
    // Original common expiry/admission owners1005f6e04/1006002f4 supply the
    // boundaries; original Library10061230c supplies every outgoing field.
    // Synthetic successful protobufs below are response inputs, not expected
    // requests. No UI, timer, filesystem cache or account is exercised.
    for (final ttl in [(entity: 0, provider: 100), (entity: 100, provider: 1)]) {
      var now = 1700000000000000;
      final outgoing = <RequestEnvelope>[];
      final response = BatchedExtensionResponse(extendedMetadata: [EntityExtensionDataArray(
        extensionKind: ExtensionKind.ALBUM_V4,
        header: EntityExtensionDataArrayHeader(providerErrorStatus: 200,
          cacheTtlInSeconds: Int64(ttl.provider)),
        extensionData: [EntityExtensionData(entityUri: uris.single,
          header: EntityExtensionDataHeader(statusCode: 200, cacheTtlInSeconds: Int64(ttl.entity)),
          extensionData: Any(typeUrl: 'type.googleapis.com/spotify.metadata.Album',
            value: v4.Album(name: 'Synthetic response').writeToBuffer()))])]).writeToBuffer();
      final client = NativeLibraryMetadataClient(requests: SpotifyRequests(
        baseUrl: 'https://spclient.example.test:443/', inheritedHeaders: const {},
        defaults: NativeHttpDefaults(userAgent: expected['headers']['User-Agent'] as String)),
        country: input['country'] as String, catalogue: input['catalogue'] as String,
        imageUrlTemplate: 'https://i.scdn.co/image/{file_id}', nowMicroseconds: () => now,
        send: (request) async { outgoing.add(request); return http.Response.bytes(response, 200); });
      await client.describe(uris);
      expect(outgoing.length, 1);
      for (final boundary in boundaries) {
        now = boundary['nowMicroseconds'] as int;
        await client.describe(uris);
        expect(outgoing.length, boundary['originalFresh'] == true ? 1 : 2,
          reason: 'entity/provider TTL=$ttl at original time$now');
      }
      for (final request in outgoing) {
        expect(request.method, expected['method']);
        expect(request.url, expected['rawUrl']);
        expect(request.headers, expected['headers']);
        expect(request.body, hex.decode(expected['bodyHex'] as String));
      }
    }
  });
}
