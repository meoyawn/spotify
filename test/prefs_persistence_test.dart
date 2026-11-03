import 'dart:convert';
import 'dart:io';

import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spotify_flutter/protocol/generated/es_prefs.pb.dart' as proto;
import 'package:spotify_flutter/protocol/prefs_codec.dart';
import 'package:spotify_flutter/protocol/prefs_persistence.dart';
import 'package:spotify_flutter/protocol/prefs_store.dart';

class _Tasks {
  final callbacks = <void Function()>[];
  PrefsFlushCancel schedule(void Function() callback) {
    var cancelled = false;
    callbacks.add(() { if (!cancelled) callback(); });
    return () { cancelled = true; };
  }
}

void main() {
  group('Owned preference files', () {
    late Directory directory;
    setUp(() async {
      directory = await Directory.systemTemp.createTemp('spotify-owned-prefs-');
      addTearDown(() => directory.delete(recursive: true));
    });

    test('native coalescing and failed-write policy preserves the destination until retry succeeds', () async {
      final fixture = jsonDecode(File('reverse-engineering/fixtures/native-prefs-codec.json').readAsStringSync()) as Map<String, dynamic>;
      final observations = fixture['flushPolicy']['observations'] as List;
      final file = File('${directory.path}/prefs');
      await file.writeAsString('enabled=false\n');
      final blockedTemporary = Directory('${file.path}.tmp');
      await blockedTemporary.create();
      final store = PrefsStore()..register('enabled', proto.Value(bool_2: false), flags: 4);
      addTearDown(store.close);
      final tasks = _Tasks();
      final owner = await PrefsPersistence.open(store: store, file: file, scope: PrefsScope.desktop, schedule: tasks.schedule);
      addTearDown(owner.close);
      expect(owner.loadSucceeded, isTrue);
      for (final value in [true, false, true]) {
        store.set({'enabled': proto.Value(bool_2: value)});
      }
      expect(owner.dirty, observations[2]['dirty']);
      expect(tasks.callbacks.length, observations[2]['scheduled']);
      expect(await owner.flush(), isFalse);
      expect(owner.dirty, observations[3]['dirty']);
      expect(await file.readAsString(), 'enabled=false\n');
      expect(owner.lastError, isA<FileSystemException>());
      await blockedTemporary.delete();
      store.set({'enabled': proto.Value(bool_2: false)});
      expect(tasks.callbacks.length, observations[4]['scheduled']);
      expect(await owner.flush(), isTrue);
      expect(owner.dirty, observations[5]['dirty']);
      expect(await file.readAsBytes(), isEmpty);
      expect(await File('${file.path}.tmp').exists(), isFalse);
      expect(owner.lastError, isNull);
    });

    test('mutations during asynchronous IO reach disk and close drains queued values', () async {
      final file = File('${directory.path}/prefs');
      final store = PrefsStore()..register('counter', proto.Value(number: Int64.ZERO), flags: 4);
      addTearDown(store.close);
      final tasks = _Tasks();
      final owner = await PrefsPersistence.open(store: store, file: file, scope: PrefsScope.desktop, schedule: tasks.schedule);
      addTearDown(owner.close);
      expect(owner.loadSucceeded, isFalse);
      store.set({'counter': proto.Value(number: Int64(1))});
      final writing = owner.flush();
      store.set({'counter': proto.Value(number: Int64(2))});
      store.set({'counter': proto.Value(number: Int64(3))});
      expect(await writing, isTrue);
      expect(await file.readAsString(), 'counter=3\n');
      expect(owner.dirty, isFalse);
      store.set({'counter': proto.Value(number: Int64(4))});
      expect(await owner.close(), isTrue);
      store.set({'counter': proto.Value(number: Int64(5))});
      for (final callback in tasks.callbacks) { callback(); }
      expect(await file.readAsString(), 'counter=4\n');
    });

    test('separate explicit files apply exact scope ownership and restore on restart', () async {
      final desktopFile = File('${directory.path}/desktop-prefs');
      final userFile = File('${directory.path}/user-prefs');
      final store = PrefsStore()
        ..register('desktop', proto.Value(bool_2: false), flags: 4)
        ..register('user', proto.Value(bool_2: false), flags: 8)
        ..register('mixed', proto.Value(bool_2: false), flags: 12)
        ..register('transient', proto.Value(bool_2: false))
        ..register('durable', proto.Value(bool_2: false), flags: 0x1004);
      addTearDown(store.close);
      final desktopTasks = _Tasks();
      final userTasks = _Tasks();
      final desktop = await PrefsPersistence.open(store: store, file: desktopFile,
        scope: PrefsScope.desktop, schedule: desktopTasks.schedule);
      final user = await PrefsPersistence.open(store: store, file: userFile,
        scope: PrefsScope.authenticated, schedule: userTasks.schedule);
      addTearDown(desktop.close);
      addTearDown(user.close);
      store.set({for (final key in ['desktop', 'user', 'mixed', 'transient', 'durable']) key: proto.Value(bool_2: true)});
      expect(desktopTasks.callbacks.length, 1);
      expect(userTasks.callbacks.length, 1);
      expect(desktopFile.existsSync(), isFalse);
      expect(userFile.existsSync(), isFalse);
      expect(await Future.wait([desktop.flush(), user.flush()]), [true, true]);
      final desktopValues = PrefsCodec.decode(await desktopFile.readAsBytes()).map((entry) => entry.toProtobuf()).toList();
      final userValues = PrefsCodec.decode(await userFile.readAsBytes()).map((entry) => entry.toProtobuf()).toList();
      expect(desktopValues.map((entry) => entry.key), unorderedEquals(['desktop', 'durable']));
      expect(userValues.map((entry) => entry.key), ['user']);
      await desktop.close();
      final restored = PrefsStore()..register('desktop', proto.Value(bool_2: false), flags: 4);
      addTearDown(restored.close);
      final reopened = await PrefsPersistence.open(store: restored, file: desktopFile,
        scope: PrefsScope.desktop, schedule: _Tasks().schedule);
      addTearDown(reopened.close);
      expect(reopened.loadSucceeded, isTrue);
      expect(restored.get('desktop').entries['desktop']!.bool_2, isTrue);
      expect(reopened.dirty, isFalse);
    });

    test('read bound is strict and invalid UTF-8 bridge failures leave the store intact', () async {
      final file = File('${directory.path}/prefs');
      await file.writeAsBytes(List.filled(PrefsPersistence.readLimit, 32));
      final store = PrefsStore()..register('valid', proto.Value(bool_2: false), flags: 4);
      addTearDown(store.close);
      final tooLarge = await PrefsPersistence.open(store: store, file: file, scope: PrefsScope.desktop);
      expect(tooLarge.loadSucceeded, isFalse);
      expect(tooLarge.lastError, isA<FileSystemException>());
      await tooLarge.close();
      await file.writeAsBytes([...ascii.encode('valid=true\n'), ...List.filled(PrefsPersistence.readLimit - 12, 32)]);
      final belowLimit = await PrefsPersistence.open(store: store, file: file, scope: PrefsScope.desktop);
      expect(belowLimit.loadSucceeded, isTrue);
      expect(store.get('valid').entries['valid']!.bool_2, isTrue);
      await belowLimit.close();
      store.set({'valid': proto.Value(bool_2: false)});
      await file.writeAsString('valid=true\ninvalid="\\xFF"\n');
      final invalid = await PrefsPersistence.open(store: store, file: file, scope: PrefsScope.desktop);
      addTearDown(invalid.close);
      expect(invalid.loadSucceeded, isFalse);
      expect(invalid.lastError, isA<FormatException>());
      expect(store.get('valid').entries['valid']!.bool_2, isFalse);
    });
  });
}
