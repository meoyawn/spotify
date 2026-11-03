import 'dart:async';

import 'esperanto.dart';
import 'generated/es_prefs.pb.dart' as proto;
import 'prefs_store.dart';

/// Local registered implementation of the original native preference service.
class DesktopPrefsService {
  const DesktopPrefsService(this.store);
  static const id = 'spotify.prefs.esperanto.proto.Prefs';
  final PrefsStore store;

  void register(EsperantoDispatcher dispatcher) {
    dispatcher.register(id, EsperantoService(single: {
      'Get': (request) => store.get(proto.GetParams.fromBuffer(request).key).writeToBuffer(),
      'GetAll': (request) {
        proto.GetAllParams.fromBuffer(request);
        return store.getAll().writeToBuffer();
      },
      'Set': (request) => store.set(proto.SetParams.fromBuffer(request).entries).writeToBuffer(),
      'Create': (request) => store.create(proto.CreateParams.fromBuffer(request).entries).writeToBuffer(),
    }, streaming: {
      'Sub': (request) => _subscribe(proto.SubParams.fromBuffer(request).key),
      'SubAll': (request) {
        proto.SubAllParams.fromBuffer(request);
        return _subscribe(null);
      },
    }));
  }

  Stream<List<int>> _subscribe(String? key) {
    final selectedKey = key?.split('\u0000').first;
    StreamSubscription<PrefsChange>? subscription;
    late StreamController<List<int>> controller;
    controller = StreamController<List<int>>(onListen: () {
      controller.add((selectedKey == null ? store.getAll() : store.get(selectedKey)).writeToBuffer());
      subscription = store.changes.listen((change) {
        if (selectedKey != null && !(selectedKey.isEmpty || (selectedKey.endsWith('.')
            ? change.key.startsWith(selectedKey) : change.key == selectedKey))) {
          return;
        }
        final values = selectedKey == null ? change.values : proto.PrefValues(
          entries: change.values.entries.entries.where((item) => item.key == selectedKey));
        controller.add(values.writeToBuffer());
      }, onError: controller.addError, onDone: controller.close);
    }, onCancel: () => subscription?.cancel());
    return controller.stream;
  }
}
