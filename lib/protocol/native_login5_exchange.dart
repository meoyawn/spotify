import 'dart:async';

import 'package:cancellation_token/cancellation_token.dart';
import 'package:http/http.dart' as http;

import '../async/cancellation.dart';
import 'generated/spotify/login5/v3/login5.pb.dart' as proto;
import 'native_login5_credentials.dart';
import 'native_login5_request.dart';
import 'native_login5_response.dart';

/// A real native transport error outside the known "http" category. Adapters
/// must classify it explicitly; arbitrary Dart exceptions retain their identity.
class NativeLogin5OtherTransportFailure implements Exception {
  const NativeLogin5OtherTransportFailure(this.cause);
  final Object cause;
}

class NativeLogin5OwnedSend {
  NativeLogin5OwnedSend({required this.response, required void Function() cancel}) : _cancelOwnedSend = cancel;
  final Future<http.Response> response;
  final void Function() _cancelOwnedSend;
  final _cancellation = CancellationToken();
  void cancel() {
    if (_cancellation.isCancelled) return;
    _cancellation.cancel();
    _cancelOwnedSend();
  }
}

class NativeLogin5ChallengeContext {
  const NativeLogin5ChallengeContext({required this.responseAtMicroseconds, required this.savedResponseAttempts,
    this.cancellationToken});
  final int responseAtMicroseconds, savedResponseAttempts;
  final CancellationToken? cancellationToken;
}

/// Supplied whole-task executor. It owns ordered challenge execution and raw
/// numeric method validation, including SMS methods 0/1 and code_length >= 0.
/// Release drops this exchange's task handle/continuation; it is not a claim
/// that an underlying solver or SMS UI can be forcibly aborted.
class NativeLogin5OwnedChallenges {
  NativeLogin5OwnedChallenges({required this.solutions, required void Function() release}) : _releaseOwnedChallenges = release;
  final Future<proto.ChallengeSolutions> solutions;
  final void Function() _releaseOwnedChallenges;
  final _cancellation = CancellationToken();
  void release() {
    if (_cancellation.isCancelled) return;
    _cancellation.cancel();
    _releaseOwnedChallenges();
  }
}

typedef NativeLogin5SendOwner = NativeLogin5OwnedSend Function(NativeLogin5RequestPlan plan);
typedef NativeLogin5ChallengeOwner = NativeLogin5OwnedChallenges Function(
  NativeLogin5ChallengeContinuation continuation, NativeLogin5ChallengeContext context);
typedef NativeLogin5DeliveryExecutor = void Function(void Function() deliver);

/// One native v3 task per start, sharing the supplied API-owner retry counter.
/// Every side-effect boundary is required; this component creates no transport,
/// solver, UI, session, wall clock, or default remote sender.
class NativeLogin5V3Exchange {
  NativeLogin5V3Exchange({required this.planner, required this.sendOwned,
    required this.executeChallenges, required this.executeDelivery, required this.nowMicroseconds});
  final NativeLogin5RequestPlanner planner;
  final NativeLogin5SendOwner sendOwned;
  final NativeLogin5ChallengeOwner executeChallenges;
  /// Must enqueue rather than invoke inline, matching the native result queue.
  final NativeLogin5DeliveryExecutor executeDelivery;
  final int Function() nowMicroseconds;

  NativeLogin5V3Run start({required NativeLogin5Credentials credentials, required NativeLogin5Credential credential,
      CancellationToken? cancellationToken}) {
    final run = NativeLogin5V3Run._(this, credentials, credential);
    run._parent = CancellationRegistration(cancellationToken, onCancel: (_) => run.cancel());
    if (cancellationToken?.isCancelled == true) { run.cancel(); return run; }
    run._begin();
    return run;
  }
}

class NativeLogin5V3Run {
  NativeLogin5V3Run._(this._exchange, this._credentials, NativeLogin5Credential credential)
    : _credential = credential, _classifier = NativeLogin5V3Classifier(credentials: _credentials,
        credential: credential, nowMicroseconds: _exchange.nowMicroseconds);
  final NativeLogin5V3Exchange _exchange;
  final NativeLogin5Credentials _credentials;
  final NativeLogin5Credential _credential;
  final NativeLogin5V3Classifier _classifier;
  final _result = Completer<NativeLogin5V3Result>();
  // The public Future retains this operation until delivery. Afterwards the
  // owned scope is released; late external Futures retain only weak frames.
  late final Future<NativeLogin5V3Result> _future = _result.future.whenComplete(_releaseAfterDelivery);
  Future<NativeLogin5V3Result> get result => _future;
  NativeLogin5OwnedSend? _send;
  NativeLogin5OwnedChallenges? _challenges;
  _SendFrame? _sendFrame;
  _ChallengeFrame? _challengeFrame;
  final _cancellation = CancellationToken();
  CancellationRegistration? _parent;
  bool _delivered = false, _httpStopped = false, _observerOwned = true;
  bool get _alive => !_delivered && !_cancellation.isCancelled;
  NativeLogin5V3Result? _cached;
  Object? _cachedError;
  StackTrace? _cachedStack;

  void _begin() {
    _future;
    try { _sendRequest(_credentials.build(_credential), null); }
    catch (error, stack) { _failed(error, stack); }
  }

  void _sendRequest(proto.LoginRequest request, _SavedResponse? saved) {
    if (!_alive) return;
    _httpStopped = false;
    final plan = _exchange.planner.plan(version: NativeLogin5Version.v3, body: request.writeToBuffer(),
      cancellationToken: _cancellation);
    final owner = _exchange.sendOwned(plan);
    final previous = _send;
    _sendFrame?.detach();
    _send = owner;
    final frame = _SendFrame(this, owner, saved);
    _sendFrame = frame;
    previous?.cancel();
    if (!_alive || _httpStopped) { frame.detach(); _send = null; owner.cancel(); }
    owner.response.then<void>(frame.received, onError: frame.failed);
  }

  void _sendReceived(_SendFrame frame, http.Response response) {
    if (!_alive || _httpStopped || !identical(_sendFrame, frame)) return;
    try { _received(response, frame.saved); }
    catch (error, stack) { _failed(error, stack); }
  }

  void _sendFailed(_SendFrame frame, Object error, StackTrace stack) {
    if (!_alive || _httpStopped || !identical(_sendFrame, frame)) return;
    if (error is NativeLogin5HttpFailure || error is NativeLogin5OtherTransportFailure) {
      _exchange.planner.recordTransportFailure(error);
      if (error is NativeLogin5HttpFailure && error.code == 10) return;
      _publish(const NativeLogin5Failure(4));
    } else {
      _failed(error, stack);
    }
  }

  void _received(http.Response response, _SavedResponse? saved) {
    if (response.statusCode != 200) {
      _exchange.planner.recordHttpResponse(statusCode: response.statusCode, parsedNonemptyBody: false);
      _publish(const NativeLogin5Failure(3));
      return;
    }
    final NativeLogin5V3Response decoded;
    try { decoded = NativeLogin5V3Response.decode(response.bodyBytes); }
    on NativeLogin5Failure catch (failure) {
      _exchange.planner.recordHttpResponse(statusCode: 200, parsedNonemptyBody: false);
      _publish(failure);
      return;
    }
    _exchange.planner.recordHttpResponse(statusCode: 200, parsedNonemptyBody: true);
    // The HTTP callback reads once for challenge expiry; success dispatch
    // independently reads the actual clock again through the classifier.
    final responseAt = _exchange.nowMicroseconds();
    _dispatch(decoded, responseAt, saved);
  }

  void _dispatch(NativeLogin5V3Response response, int responseAt, _SavedResponse? saved) {
    if (!_alive) return;
    final projected = _classifier.classify(response, savedResponse: saved?.response);
    if (projected is NativeLogin5SavedResponseFallback) {
      final prior = saved!;
      _dispatch(projected.response, prior.atMicroseconds,
        _SavedResponse(prior.response, prior.atMicroseconds, prior.attempts + projected.attemptIncrement));
    } else if (projected is NativeLogin5ChallengeContinuation) {
      _executeChallenges(projected, responseAt, saved?.attempts ?? 0);
    } else {
      _publish(projected);
    }
  }

  void _executeChallenges(NativeLogin5ChallengeContinuation continuation, int responseAt, int attempts) {
    final owner = _exchange.executeChallenges(continuation,
      NativeLogin5ChallengeContext(responseAtMicroseconds: responseAt, savedResponseAttempts: attempts,
        cancellationToken: _cancellation));
    _challenges = owner;
    final frame = _ChallengeFrame(this, owner, continuation, responseAt, attempts);
    _challengeFrame = frame;
    if (!_alive) { frame.detach(); _challenges = null; owner.release(); }
    owner.solutions.then<void>(frame.solved, onError: frame.failed);
  }

  void _challengeSolved(_ChallengeFrame frame, proto.ChallengeSolutions solutions) {
    if (!_alive || !identical(_challengeFrame, frame)) return;
    final owner = frame.owner!, continuation = frame.continuation!;
    try {
      final request = continuation.withSolutions(solutions);
      _sendRequest(request, _SavedResponse(continuation.response, frame.responseAt, frame.attempts));
    } catch (error, stack) {
      _failed(error, stack);
    } finally {
      if (identical(_challenges, owner)) _challenges = null;
      frame.detach();
      owner.release();
    }
  }

  void _challengeFailed(_ChallengeFrame frame, Object error, StackTrace stack) {
    if (!_alive || !identical(_challengeFrame, frame)) return;
    final owner = frame.owner!;
    _challenges = null;
    try { _failed(error, stack); }
    finally { frame.detach(); owner.release(); }
  }

  void _failed(Object error, StackTrace stack) {
    if (error is NativeLogin5Failure) { _publish(error); }
    else { _publishError(error, stack); }
  }

  void _publish(NativeLogin5V3Result value) {
    _cached = value;
    _cachedError = null;
    _cachedStack = null;
    _queueObserver();
  }

  void _publishError(Object error, StackTrace stack) {
    _cached = null;
    _cachedError = error;
    _cachedStack = stack;
    _queueObserver();
  }

  void _queueObserver() {
    if (!_observerOwned) return;
    _observerOwned = false;
    _exchange.executeDelivery(() {
      final value = _cached, error = _cachedError, stack = _cachedStack;
      _cached = null;
      _cachedError = null;
      _cachedStack = null;
      if (error != null) { _result.completeError(error, stack); }
      else if (value != null) { _result.complete(value); }
    });
  }

  /// Mirrors scoped owner cancellation: stop HTTP callbacks/work, publish
  /// failure1, then expire task continuations and release the provided handle.
  void cancel() {
    if (!_alive) return;
    _httpStopped = true;
    _sendFrame?.detach();
    try { _send?.cancel(); }
    finally {
      _publish(const NativeLogin5Failure(1));
      _cancellation.cancel();
      _send = null;
      final owner = _challenges;
      _challenges = null;
      _challengeFrame?.detach();
      owner?.release();
    }
  }

  void _releaseAfterDelivery() {
    _delivered = true;
    _parent?.dispose(); _parent = null;
    _httpStopped = true;
    _sendFrame?.detach();
    _challengeFrame?.detach();
    final send = _send, challenges = _challenges;
    _send = null;
    _challenges = null;
    try { send?.cancel(); }
    finally { challenges?.release(); }
  }
}

class _SavedResponse {
  const _SavedResponse(this.response, this.atMicroseconds, this.attempts);
  final NativeLogin5V3Response response;
  final int atMicroseconds, attempts;
}

class _SendFrame {
  _SendFrame(NativeLogin5V3Run run, this.owner, this.saved) : _run = WeakReference(run);
  final WeakReference<NativeLogin5V3Run> _run;
  NativeLogin5OwnedSend? owner;
  _SavedResponse? saved;
  void received(http.Response response) { if (owner != null) _run.target?._sendReceived(this, response); }
  void failed(Object error, StackTrace stack) { if (owner != null) _run.target?._sendFailed(this, error, stack); }
  void detach() { owner = null; saved = null; }
}

class _ChallengeFrame {
  _ChallengeFrame(NativeLogin5V3Run run, this.owner, this.continuation, this.responseAt, this.attempts) : _run = WeakReference(run);
  final WeakReference<NativeLogin5V3Run> _run;
  NativeLogin5OwnedChallenges? owner;
  NativeLogin5ChallengeContinuation? continuation;
  final int responseAt, attempts;
  void solved(proto.ChallengeSolutions solutions) { if (owner != null) _run.target?._challengeSolved(this, solutions); }
  void failed(Object error, StackTrace stack) { if (owner != null) _run.target?._challengeFailed(this, error, stack); }
  void detach() { owner = null; continuation = null; }
}
