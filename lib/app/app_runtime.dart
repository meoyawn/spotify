import 'dart:io';
import 'dart:typed_data';

import 'package:cancellation_token/cancellation_token.dart';
import 'package:flutter/foundation.dart';

import '../entities/repository.dart';
import '../home/repository.dart';
import '../library/repository.dart';
import '../library/saved_tracks.dart';
import '../playback/audio_source.dart';
import '../playback/engine.dart';
import '../protocol/prefs_store.dart';
import '../search/repository.dart';

/// The token owns initialization and the resulting runtime's application lifetime.
typedef SpotifyAppRuntimeFactory = Future<SpotifyAppRuntime> Function({
  required String deviceId, required PrefsStore preferences,
  required Directory streamingDirectory, CancellationToken? cancellationToken});

/// The desktop UI's single Dart session owner. Native boundaries provide only
/// standard platform primitives, transport, decoding and device audio output.
abstract interface class SpotifyAppRuntime {
  ValueListenable<String> get status;
  bool get ready;
  String? get username;
  SearchRepository? get searchRepository;
  HomeRepository? get homeRepository;
  LibraryRepository? get libraryRepository;
  SavedTracksRepository? get savedTracksRepository;
  EntityRepository? get entityRepository;
  Future<void> signIn({CancellationToken? cancellationToken});
  Future<void> cancelSignIn();
  Future<void> signOut();
  Future<PreparedAudioFile> resolve(String uri, {CancellationToken? cancellationToken});
  Future<Uint8List> artwork(String rawUrl, {CancellationToken? cancellationToken});
  void bindEngine(PlaybackEngine engine);
  Future<void> close();
}
