# AP wire overlays

These two schemas preserve the pinned MIT librespot reference and add only
bounded fields proved by original installed-client instructions. They are
reference-derived schemas, **not extracted original descriptors**. The original
files remain unchanged in `native/librespot/upstream/protocol/proto/`; the
retained MIT license is [LICENSE](LICENSE).

`native_field_*` and `NativeFeatureSetField*` are explicit aliases for names that
were not recovered. The additions are:

| Message | Native additions | Original writer |
| --- | --- | --- |
| FeatureSet | message 3, bool 4, message 5 | `0x10190a8e8` |
| NativeFeatureSetField3 | bools 1–4 | `0x10190a39c` |
| NativeFeatureSetField5 | bool 1 | `0x10190a620` |
| ClientResponseEncrypted | caller text 11 | `0x101913bd0` |
| LoginCredentials | opaque password padding 40 | `0x10190e6c4` |
| ClientInfo | caller text 4 and 5 | `0x101912958` |

The original writers condition these fields on has-bits. Independent native
serialization records explicit false values, nested-message presence and bytes;
the overlay uses ordinary proto2 optional fields to preserve those observations.
Required/optional labels and string/bytes declarations for unknown fields are
modeling choices, not original declaration recovery. Text aliases follow the
observed caller inputs; padding remains opaque bytes.

These AP objects do not expose the modern Login5 ClassDataLite/TcParseTable
metadata. Their observed older vtables/lazy records cannot be fed to the Login5
table extractor. The evidence instead executes the original constructors,
generated writers and parser with synthetic inputs. Standard protobuf/runtime
dependencies execute unchanged and are not decompiled or ported.

The fixture also records narrower parser constraints that ordinary `.proto`
bytes fields cannot express. Sampled native APWelcome parsing accepts absent
`lfs_secret` or 20 bytes and rejects 12, 16 and 32 bytes. The sampled full AP
challenge rejects a 128-byte server signature and accepts 256 bytes with its
96-byte public value and 16-byte nonce. This does not prove every possible
message, enum domain or server response. In particular, native typed
AuthenticationType parsing preserves sampled values 10 and 255 as well as 0–9;
no invented enum labels or 0–9 range restriction are added.

The public synthetic proof is [native-ap-schemas.json](../../../reverse-engineering/fixtures/native-ap-schemas.json).
It records the executable digest, source-specific writer export hashes and
independent public-protoc comparisons. Check the Dart overlay against these
retained original outputs using:

```
flutter test --no-pub test/native_ap_schema_test.dart
```

`proto/librespot-playback.json` pins the untouched base files, overlays, license,
proof, oracle and original executable identity. The generator validates these
pins and compiles the overlays to the same ignored Dart filenames:

```
uv run --project tools/oracles --locked python tools/generate_playback_protocols.py
uv run --project tools/oracles --locked python tools/generate_playback_protocols.py --check
```

Ordinary generation uses the public pinned schemas/proof and does not read an
account, original credential store or live Spotify service. The original
99-descriptor pipeline and its generated directory are separate and unchanged.
