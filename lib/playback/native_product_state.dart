import '../protocol/expat_xml.dart';

/// AP ProductInfo projection from original 0x101d636d0/0x101d63564.
/// A failed parse preserves the last successful snapshot. A successful document
/// replaces it, including when products/product is missing or not an object.
/// Attributes and repeated elements follow the original proprietary SAX owner;
/// parsing XML syntax itself uses the system's standard Expat library in process.
class NativeProductState {
  Map<String, String> _attributes = const {};
  Map<String, String> get attributes => _attributes;

  bool applyPayload(List<int> bytes) {
    final root = _ProductXmlValue('');
    final stack = <_ProductXmlValue>[root];
    var pending = StringBuffer();

    void finish() {
      final current = stack.removeLast();
      final value = pending.toString();
      // Native ignores a text run only when every byte is SP/TAB/LF/CR.
      if (value.codeUnits.any((c) => c != 32 && c != 9 && c != 10 && c != 13)) {
        if (current.value is Map<String, Object?>) {
          (current.value as Map<String, Object?>)['cdata'] = value;
        } else if (current.value == null) {
          current.value = value;
        }
      }
      pending = StringBuffer();
      stack.last.add(current.name, current.value);
    }

    final parsed = parseExpatXml(bytes, onStart: (name, attributes) {
      // The native text buffer is shared and cleared at every start tag.
      pending = StringBuffer();
      final current = _ProductXmlValue(name);
      for (final attribute in attributes.entries) { current.add(attribute.key, attribute.value); }
      stack.add(current);
    }, onEnd: (_) => finish(), onText: (text) => pending.write(text));
    if (!parsed) return false;
    final products = root.member('products');
    final product = products is Map<String, Object?> ? products['product'] : null;
    _attributes = Map.unmodifiable(product is Map<String, Object?>
      ? product.map((key, value) => MapEntry(key, value is String ? value : ''))
      : <String, String>{});
    return true;
  }
}

class _ProductXmlValue {
  _ProductXmlValue(this.name);
  final String name;
  Object? value;

  Object? member(String name) => value is Map<String, Object?>
    ? (value as Map<String, Object?>)[name] : null;

  void add(String name, Object? child) {
    final properties = value is Map<String, Object?>
      ? value as Map<String, Object?> : <String, Object?>{};
    value = properties;
    if (!properties.containsKey(name)) {
      properties[name] = child;
    } else {
      final previous = properties[name];
      if (previous is List<Object?>) {
        previous.add(child);
      } else {
        properties[name] = <Object?>[previous, child];
      }
    }
  }
}
