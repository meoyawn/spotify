import 'dart:async';
import 'dart:collection';

import 'package:http2/src/streams/stream_handler.dart' as standard;
import 'package:http2/transport.dart' as h2;

/// Per-connection HEADERS dependencies from the pinned public original
/// Http2PriorityDependencies::OnStreamCreation/OnStreamDestruction routines.
/// reverse-engineering/evidence/native-http2-priority.json records original execution and
/// captured native/renderer profiles. This owns no local write scheduling.
class NativeHttp2PriorityDependencies {
  static const nativePriorityBand = 4, rendererPriorityBand = 1;
  static const _weights = [256, 220, 183, 147, 110, 74, 37, 1];
  final _bands = List.generate(8, (_) => LinkedList<_PriorityStream>());
  final _streams = <int, _PriorityStream>{};

  h2.ClientTransportStream makeRequest(h2.ClientTransportConnection connection,
      List<h2.Header> headers, {required int priorityBand, required bool endStream}) {
    RangeError.checkValidIndex(priorityBand, _bands, 'priorityBand');
    // A completed stream may precede its Future callbacks in this turn.
    // Retire only the standard transport's terminal state, never headers or
    // one half-close while the opposite direction still has pending data.
    for (final entry in _streams.values.toList()) {
      if (entry.stream.state == standard.StreamState.Terminated) _remove(entry.stream.id);
    }
    var parent = 0;
    for (var band = priorityBand; band >= 0; band--) {
      if (_bands[band].isNotEmpty) { parent = _bands[band].last.stream.id; break; }
    }
    final stream = connection.makeRequest(headers, endStream: endStream,
      priority: h2.HeadersPriority(streamDependency: parent,
        weight: _weights[priorityBand], exclusive: true)) as standard.Http2StreamImpl;
    final entry = _PriorityStream(stream);
    _bands[priorityBand].add(entry);
    _streams[stream.id] = entry;
    // Follow both standard queues, including reset/error completion. Adapter
    // lease release alone is insufficient when an upload is still buffered.
    unawaited(Future.wait([stream.incomingQueue.done, stream.outgoingQueue.done]).then<void>(
      (_) => _remove(stream.id), onError: (Object _, StackTrace __) { _remove(stream.id); }));
    return stream;
  }

  void _remove(int streamId) => _streams.remove(streamId)?.unlink();
}

final class _PriorityStream extends LinkedListEntry<_PriorityStream> {
  _PriorityStream(this.stream);
  final standard.Http2StreamImpl stream;
}
