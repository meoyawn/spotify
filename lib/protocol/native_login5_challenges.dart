import 'dart:async';

import 'package:cancellation_token/cancellation_token.dart';
import 'package:protobuf/protobuf.dart' show CodedBufferReader;

import '../async/cancellation.dart';
import 'generated/spotify/login5/v3/challenges/code.pb.dart' as code;
import 'generated/spotify/login5/v3/login5.pb.dart' as proto;
import 'hashcash.dart';
import 'native_login5_exchange.dart';
import 'native_login5_response.dart';

typedef NativeLogin5HashcashWorker = FutureOr<HashcashSolution> Function({
  required List<int> context, required List<int> prefix, required int difficulty,
  CancellationToken? cancellationToken});
typedef NativeLogin5SmsObserver = void Function(NativeLogin5SmsChallenge challenge);

/// An actual native SMS prompt. The owner supplies its UI/interaction; neither
/// callback has a default answer. Submit and skip share one consumption gate.
class NativeLogin5SmsChallenge {
  NativeLogin5SmsChallenge._(_RawCode value, this.expiresAtMicroseconds,
      this.savedResponseAttempts, this._frame)
    : method = value.method, codeLength = value.length, phoneNumber = value.phone,
      expiresInSeconds = value.expires;
  final int method, codeLength, expiresInSeconds, expiresAtMicroseconds, savedResponseAttempts;
  final String phoneNumber;
  final _SmsFrame _frame;
  void submit(String value) => _frame.complete(value);
  /// Native failure callback advances without appending a solution.
  void skip() => _frame.complete(null);
}

/// Port of the original ordered v3 task. All interaction, CPU scheduling and
/// clocks are explicit dependencies; this owner installs no UI or sender.
class NativeLogin5V3ChallengeExecutor {
  const NativeLogin5V3ChallengeExecutor({required this.observeSms,
    required this.solveHashcash, required this.nowNanoseconds});
  final NativeLogin5SmsObserver observeSms;
  final NativeLogin5HashcashWorker solveHashcash;
  final int Function() nowNanoseconds;

  NativeLogin5OwnedChallenges call(NativeLogin5ChallengeContinuation continuation,
      NativeLogin5ChallengeContext context) {
    final task = _ChallengeTask(this, continuation, context);
    final owner = NativeLogin5OwnedChallenges(solutions: task.result, release: task.release);
    task.start();
    return owner;
  }
}

class _ChallengeTask {
  _ChallengeTask(this.executor, this.continuation, this.context) {
    _parent = CancellationRegistration(context?.cancellationToken, onCancel: (_) => release());
  }
  final NativeLogin5V3ChallengeExecutor executor;
  NativeLogin5ChallengeContinuation? continuation;
  NativeLogin5ChallengeContext? context;
  final _completion = Completer<proto.ChallengeSolutions>();
  Future<proto.ChallengeSolutions> get result => _completion.future;
  List<_RawCode?> _codes = [];
  List<proto.Challenge> _items = [];
  final List<proto.ChallengeSolution> _answers = [];
  _SmsFrame? _sms;
  _HashcashFrame? _hashcash;
  int _index = 0;
  final _cancellation = CancellationToken();
  CancellationRegistration? _parent;
  bool _finished = false;
  bool get _alive => !_finished && !_cancellation.isCancelled;

  void start() {
    if (context?.cancellationToken?.isCancelled == true) { release(); return; }
    try {
      _items = continuation!.response.challenges!.challenges;
      _codes = _rawCodes(continuation!.response.wireBytes);
      if (_codes.length != _items.length) throw StateError('Native challenge projection count differs');
      _advance();
    } catch (error, stack) { _failed(error, stack); }
  }

  void _advance() {
    if (!_alive) return;
    try {
      while (_index < _items.length) {
        final item = _items[_index];
        switch (item.whichChallenge()) {
          case proto.Challenge_Challenge.hashcash:
            final value = item.hashcash;
            final solved = executor.solveHashcash(context: continuation!.response.loginContext,
              prefix: List<int>.unmodifiable(value.prefix), difficulty: value.length.toUnsigned(32),
              cancellationToken: _cancellation);
            if (solved is HashcashSolution) {
              _appendHashcash(solved);
              continue;
            }
            final frame = _HashcashFrame(this);
            _hashcash = frame;
            solved.then<void>(frame.completed, onError: frame.failed);
            return;
          case proto.Challenge_Challenge.code:
            final value = _codes[_index]!;
            if ((value.method != 0 && value.method != 1) || value.length < 0) {
              throw const NativeLogin5Failure(2);
            }
            // SMS timing samples are retained at native boundaries. The
            // separate request-statistics elapsed-ms accumulator is not owned
            // by the current exchange/result API.
            executor.nowNanoseconds();
            final frame = _SmsFrame(this, executor.nowNanoseconds);
            _sms = frame;
            executor.observeSms(NativeLogin5SmsChallenge._(value,
              (context!.responseAtMicroseconds + value.expires * 1000000).toSigned(64),
              context!.savedResponseAttempts, frame));
            return;
          case proto.Challenge_Challenge.notSet:
            // The original worker returns without a callback for an unknown
            // arm. It neither manufactures a solution nor publishes failure.
            return;
        }
      }
      final answer = proto.ChallengeSolutions(solutions: _answers)..freeze();
      _finished = true;
      _clear();
      _completion.complete(answer);
    } catch (error, stack) { _failed(error, stack); }
  }

  void _appendHashcash(HashcashSolution value) {
    _answers.add(nativeLogin5HashcashAnswer(suffix: value.suffix,
      elapsedNanoseconds: value.elapsedNanoseconds));
    _index++;
  }

  void hashcashCompleted(_HashcashFrame frame, HashcashSolution value) {
    if (!_alive || !identical(_hashcash, frame)) return;
    _hashcash = null;
    try { _appendHashcash(value); _advance(); }
    catch (error, stack) { _failed(error, stack); }
  }

  void smsCompleted(_SmsFrame frame, String? value) {
    if (!_alive || !identical(_sms, frame)) return;
    _sms = null;
    if (value != null) {
      _answers.add(proto.ChallengeSolution(code: code.CodeSolution(code: value.isEmpty ? null : value)));
    }
    _index++;
    _advance();
  }

  void _failed(Object error, StackTrace stack) {
    if (!_alive) return;
    _finished = true;
    _clear();
    _completion.completeError(error, stack);
  }

  void release() {
    if (!_alive) return;
    _cancellation.cancel();
    _clear();
    // The injected worker receives this task's token and owns its CPU cleanup.
    // A late UI callback still retains only its weak continuation frame.
  }

  void _clear() {
    _parent?.dispose(); _parent = null;
    continuation = null;
    context = null;
    _items = [];
    _codes = [];
    _answers.clear();
    _sms = null;
    _hashcash = null;
  }
}

class _HashcashFrame {
  _HashcashFrame(_ChallengeTask task) : task = WeakReference(task);
  final WeakReference<_ChallengeTask> task;
  void completed(HashcashSolution value) => task.target?.hashcashCompleted(this, value);
  void failed(Object error, StackTrace stack) => task.target?._failed(error, stack);
}

class _SmsFrame {
  _SmsFrame(_ChallengeTask task, this.clock) : task = WeakReference(task);
  final WeakReference<_ChallengeTask> task;
  final int Function() clock;
  bool _consumed = false;
  void complete(String? code) {
    if (_consumed) return;
    _consumed = true;
    // Original callbacks sample even if the outer weak task has expired.
    clock();
    task.target?.smsCompleted(this, code);
  }
}

class _RawCode {
  int method = 0, length = 0, expires = 0;
  String phone = '';
}

// Standard readers own tags, varints, lengths, strings and unknown-field
// validation. This projection retains raw numeric methods that generated Dart
// enum getters lose, including merge/reset across repeated oneof occurrences.
List<_RawCode?> _rawCodes(List<int> bytes) {
  final reader = CodedBufferReader(bytes);
  var selected = false;
  final result = <_RawCode?>[];
  while (!reader.isAtEnd()) {
    final tag = reader.readTag();
    if (tag == 10 || tag == 16) {
      selected = false;
      result.clear();
      if (tag == 10) { reader.readBytes(); } else { reader.readEnum(); }
    } else if (tag == 26) {
      if (!selected) result.clear();
      selected = true;
      final challenges = CodedBufferReader(reader.readBytes());
      while (!challenges.isAtEnd()) {
        final inner = challenges.readTag();
        if (inner == 10) { result.add(_rawCode(challenges.readBytes())); }
        else if (!challenges.skipField(inner)) { break; }
      }
    } else if (!reader.skipField(tag)) { break; }
  }
  return result;
}

_RawCode? _rawCode(List<int> bytes) {
  final reader = CodedBufferReader(bytes);
  _RawCode? result;
  while (!reader.isAtEnd()) {
    final tag = reader.readTag();
    if (tag == 10) {
      result = null;
      reader.readBytes();
    } else if (tag == 18) {
      result ??= _RawCode();
      final code = CodedBufferReader(reader.readBytes());
      while (!code.isAtEnd()) {
        final field = code.readTag();
        switch (field) {
          case 8: result.method = code.readEnum();
          case 16: result.length = code.readInt32();
          case 24: result.expires = code.readInt32();
          case 34: result.phone = code.readString();
          default: if (!code.skipField(field)) return result;
        }
      }
    } else if (!reader.skipField(tag)) { break; }
  }
  return result;
}
