import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:protobuf/well_known_types/google/protobuf/any.pb.dart';
import 'package:spotify_flutter/playback/spotify_media_client.dart';
import 'package:spotify_flutter/playback/spotify_metadata.dart';
import 'package:spotify_flutter/playback/spotify_requests.dart';
import 'package:spotify_flutter/protocol/generated/entity_extension_data.pb.dart';
import 'package:spotify_flutter/protocol/generated/extended_metadata.pb.dart';
import 'package:spotify_flutter/protocol/generated/extension_kind.pbenum.dart';
import 'package:spotify_flutter/protocol/generated/metadata.pb.dart';
import 'package:spotify_flutter/protocol/native_http_defaults.dart';

void main() {
  test('typed v0 metadata matches URI and kind across shuffled extensions while retaining statuses and original fields', () async {
    const trackUri = 'spotify:track:0000000000000000000001';
    const episodeUri = 'spotify:episode:0000000000000000000002';
    const missing = 'spotify:track:0000000000000000000003';
    const ambiguous = 'spotify:episode:0000000000000000000004';
    const wrongType = 'spotify:track:0000000000000000000005';
    final unknownFormat = AudioFile(fileId: List.filled(20, 9))
      ..unknownFields.mergeVarintField(2, Int64(777));
    final track = Track(gid: List.generate(16, (index) => index), name: 'Matched track',
      file: [AudioFile(fileId: List.filled(20, 8), format: AudioFile_Format.OGG_VORBIS_160), unknownFormat],
      audioFormats: [TrackAudioFormat(originalAudio: Audio(uuid: List.filled(16, 7), format: Audio_Format.PARROT))],
      contentAccessStatus: ContentAccessStatus(gated: ContentGated()),
      restriction: [Restriction(catalogue: [Restriction_Catalogue.AD, Restriction_Catalogue.SHUFFLE],
        countriesForbidden: 'ZZ', catalogueStr: ['caller-product'])])
      ..unknownFields.mergeVarintField(999, Int64(42));
    final episode = Episode(gid: List.filled(15, 3), name: 'Matched episode',
      audio: [AudioFile(fileId: List.filled(20, 4), format: AudioFile_Format.AAC_48)],
      originalAudio: Audio(uuid: List.filled(16, 5)), restriction: [Restriction(countriesAllowed: 'YY')]);
    EntityExtensionData entry(String uri, Any payload, {int status = 200}) => EntityExtensionData(
      entityUri: uri, header: EntityExtensionDataHeader(statusCode: status, etag: 'entity-etag'), extensionData: payload);
    final trackPayload = Any(typeUrl: 'type.googleapis.com/spotify.metadata.Track', value: track.writeToBuffer());
    final episodePayload = Any(typeUrl: 'type.googleapis.com/spotify.metadata.Episode', value: episode.writeToBuffer());
    final unknownProvider = EntityExtensionDataArray(extensionKind: ExtensionKind.TRACK_V4, extensionData: [entry(trackUri,
      Any(typeUrl: 'type.googleapis.com/spotify.metadata.Track', value: Track(name: 'Wrong final group').writeToBuffer()))])
      ..unknownFields.mergeVarintField(2, Int64(500));
    final response = BatchedExtensionResponse(extendedMetadata: [
      EntityExtensionDataArray(extensionKind: ExtensionKind.EPISODE_V4,
        header: EntityExtensionDataArrayHeader(providerErrorStatus: 17, cacheTtlInSeconds: Int64(9)),
        extensionData: [entry(ambiguous, episodePayload, status: 404),
          entry(episodeUri, episodePayload, status: 403), entry(ambiguous, episodePayload, status: 429),
          entry('spotify:episode:0000000000000000000009', episodePayload)]),
      EntityExtensionDataArray(extensionKind: ExtensionKind.TRACK_V4,
        header: EntityExtensionDataArrayHeader(cacheTtlInSeconds: Int64(123), offlineTtlInSeconds: Int64(456)),
        extensionData: [entry(trackUri, trackPayload), entry(wrongType, episodePayload),
          entry('spotify:track:0000000000000000000009',
            Any(typeUrl: trackPayload.typeUrl, value: Track(name: 'Wrong final entity').writeToBuffer()))]),
      EntityExtensionDataArray(extensionKind: ExtensionKind.AUDIO_FILES,
        extensionData: [entry(trackUri, Any(typeUrl: trackPayload.typeUrl, value: Track(name: 'Wrong extension kind').writeToBuffer()))]),
      unknownProvider,
    ])..unknownFields.mergeVarintField(127, Int64(77));
    final wire = response.writeToBuffer();
    BatchedEntityRequest? captured;
    var sends = 0;
    final repository = SpotifyMetadataRepository(SpotifyMediaClient(
      requests: SpotifyRequests(baseUrl: 'https://metadata.invalid', inheritedHeaders: const {},
        defaults: const NativeHttpDefaults(userAgent: 'synthetic-explicit-user-agent')),
      send: (request) async {
        sends++;
        captured = BatchedEntityRequest.fromBuffer(request.body);
        return http.StreamedResponse(Stream.fromIterable([wire.sublist(0, 5), wire.sublist(5)]), 200);
      },
    ));
    for (final invalid in ['spotify:album:0000000000000000000001',
        'spotify:track:short', 'https://open.spotify.com/track/0000000000000000000001']) {
      await expectLater(repository.fetch([invalid]), throwsArgumentError);
    }
    expect(sends, 0);
    final result = await repository.fetch([trackUri, episodeUri, missing, ambiguous, wrongType],
      header: BatchedEntityRequestHeader(country: 'ZZ', catalogue: 'caller-product', taskId: [1, 2]));
    expect(sends, 1);
    expect(captured!.header.country, 'ZZ');
    expect(captured!.header.catalogue, 'caller-product');
    expect(captured!.header.taskId, [1, 2]);
    expect(captured!.entityRequest.map((entity) => (entity.entityUri, entity.query.single.extensionKind)), [
      (trackUri, ExtensionKind.TRACK_V4), (episodeUri, ExtensionKind.EPISODE_V4),
      (missing, ExtensionKind.TRACK_V4), (ambiguous, ExtensionKind.EPISODE_V4), (wrongType, ExtensionKind.TRACK_V4),
    ]);
    final selected = result.forUri(trackUri);
    expect(selected.problem, isNull);
    expect(selected.track, track);
    expect(selected.gid, track.gid);
    expect(selected.track!.file[1].unknownFields.getField(2)!.varints.single, Int64(777));
    expect(selected.track!.unknownFields.getField(999)!.varints.single, Int64(42));
    expect(selected.matches.single.provider.header.offlineTtlInSeconds, Int64(456));
    expect(selected.providerErrorStatus, 0);
    expect(selected.entityStatusCode, 200);
    final selectedEpisode = result.forUri(episodeUri);
    expect(selectedEpisode.episode, episode);
    expect(selectedEpisode.providerErrorStatus, 17);
    expect(selectedEpisode.entityStatusCode, 403);
    expect(selectedEpisode.matches.single.entity.header.etag, 'entity-etag');
    expect(() => selectedEpisode.gid, throwsFormatException);
    expect(result.forUri(missing).problem, SpotifyMetadataProblem.missing);
    expect(result.forUri(ambiguous).problem, SpotifyMetadataProblem.ambiguous);
    expect(result.forUri(ambiguous).matches.map((match) => match.entity.header.statusCode), [404, 429]);
    expect(result.forUri(wrongType).problem, SpotifyMetadataProblem.wrongPayloadType);
    expect(result.forUri(wrongType).track, isNull);
    expect(result.response.unknownFields.getField(127)!.varints.single, Int64(77));
    expect(result.response.extendedMetadata.last.unknownFields.getField(2)!.varints.single, Int64(500));
  });
}
