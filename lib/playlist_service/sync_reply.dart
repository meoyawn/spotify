import 'dart:convert';

import 'package:protobuf/protobuf.dart';

import '../protocol/generated/playlist_api.pb.dart';
import '../protocol/generated/native_proto3_presence.dart';

/// Category identity is significant: cancellation belongs to the exact native
/// HTTP category, not any other category with the same numeric code or name.
enum PlaylistSyncKnownCategory { http, system }

final class PlaylistSyncCode {
  const PlaylistSyncCode(this.value, this.category);

  final int value;
  /// Known categories use [PlaylistSyncKnownCategory]. Other providers retain
  /// their own opaque category object, compared by identity.
  final Object category;

  @override
  bool operator ==(Object other) => other is PlaylistSyncCode &&
    value == other.value && identical(category, other.category);

  @override
  int get hashCode => Object.hash(value, identityHashCode(category));
}

enum PlaylistSyncContentFidelity {
  complete,
  /// Native proto2 strings retain invalid UTF-8 bytes. Standard Dart strings
  /// replace them; [PlaylistSyncReply.responseBody] remains authoritative.
  lossyStrings,
  /// Parse failure leaves runtime-specific partial content. Check the error
  /// before using it; the received bytes are retained without reconstruction.
  partial,
}

final class PlaylistSyncReply {
  PlaylistSyncReply._({required this.error, required this.status,
    required this.responseStatusCode, required Map<String, String> headers,
    required List<int> responseBody, required this.content,
    required this.contentFidelity}) : headers = Map.unmodifiable(headers),
    responseBody = List.unmodifiable(responseBody);

  final PlaylistSyncCode error;
  /// Callback-compatible status pair. A parse failure replaces HTTP status
  /// with (4, http), exactly as the original callback does.
  final PlaylistSyncCode status;
  final int? responseStatusCode;
  final Map<String, String> headers;
  final List<int> responseBody;
  /// Frozen snapshot; native message-pool reuse cannot invalidate this value.
  final SelectedListContent content;
  final PlaylistSyncContentFidelity contentFidelity;
}

/// Native primary-sync completion decisions, with explicit owner lifetime.
/// Does not register Playlist.Get, send a request or supply playlist data.
final class PlaylistSyncReplyProcessor {
  PlaylistSyncReplyProcessor({required this.onReply});

  final void Function(PlaylistSyncReply) onReply;
  bool _closed = false;

  void close() { _closed = true; }

  void receiveResponse({required int statusCode, required Map<String, String> headers,
    required List<int> body}) {
    if (_closed) return;
    const http = PlaylistSyncKnownCategory.http;
    var error = const PlaylistSyncCode(0, http);
    var status = PlaylistSyncCode(statusCode, http);
    final content = SelectedListContent();
    var fidelity = PlaylistSyncContentFidelity.complete;
    if (statusCode >= 200 && statusCode < 300) {
      var parsed = true;
      try {
        content.mergeFromBuffer(body);
        // Dart's merge/fromBuffer does not enforce proto2 required fields.
        parsed = content.isInitialized();
      } on InvalidProtocolBufferException {
        parsed = false;
      }
      if (!parsed) {
        error = status = const PlaylistSyncCode(4, http);
        fidelity = PlaylistSyncContentFidelity.partial;
      } else {
        final stringState = _inspectStrings(body, content.info_);
        if (stringState == 2) {
          error = status = const PlaylistSyncCode(4, http);
          fidelity = PlaylistSyncContentFidelity.partial;
        } else if (stringState == 1) {
          fidelity = PlaylistSyncContentFidelity.lossyStrings;
        }
      }
    }
    content.freeze();
    onReply(PlaylistSyncReply._(error: error, status: status,
      responseStatusCode: statusCode, headers: headers, responseBody: body,
      content: content, contentFidelity: fidelity));
  }

  void receiveFailure(PlaylistSyncCode error) {
    if (error == const PlaylistSyncCode(10, PlaylistSyncKnownCategory.http) || _closed) return;
    final content = SelectedListContent()..freeze();
    onReply(PlaylistSyncReply._(error: error,
      status: const PlaylistSyncCode(0, PlaylistSyncKnownCategory.system),
      responseStatusCode: null, headers: const {}, responseBody: const [],
      content: content, contentFidelity: PlaylistSyncContentFidelity.complete));
  }
}

// Standard wire reader + exact generated field metadata. This observes string
// fidelity only; it never applies proto3 UTF-8 rejection to proto2 replies.
int _inspectStrings(List<int> bytes, BuilderInfo schema) {
  final reader = CodedBufferReader(bytes);
  var result = 0;
  while (true) {
    final tag = reader.readTag();
    if (tag == 0) return result;
    final field = schema.fieldInfo[tag >> 3];
    if ((tag & 7) == 2 && field != null) {
      if (PbFieldType.baseType(field.type) == PbFieldType.STRING_BIT) {
        try { utf8.decode(reader.readBytes()); }
        on FormatException {
          final malformed = nativeProto3Messages.contains(schema.qualifiedMessageName) ? 2 : 1;
          if (malformed > result) result = malformed;
        }
        continue;
      }
      final child = field is MapFieldInfo ? field.mapEntryBuilderInfo : field.subBuilder?.call().info_;
      if (child != null) {
        final malformed = _inspectStrings(reader.readBytes(), child);
        if (malformed > result) result = malformed;
        continue;
      }
    }
    if (!reader.skipField(tag)) return result;
  }
}
