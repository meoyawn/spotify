# Reconstructed Login5 models

These schemas are **reconstructed**, not extracted original descriptors. They
are kept separate from `proto/source`, `reverse-engineering/protobuf/original.pbdesc`, the exact
manifest, and its selected root counts.

The current validated subset contains 49 complete native messages and 122
fields: all 22 v3 messages and 27 enum-free v4 messages. It checks 64 retained
field names, native scalar/message kinds, field numbers, cardinality,
submessage identities, repeated packing, and oneof partitions. Standard
`protoc 36.2` compiles the readable sources to `reconstructed.pbdesc`.

Reproduce from the repository root:

```sh
cd tools/proto-export
go run . -repo ../.. -reconstruct-lite
go test .
```

The isolated CLI branch does not change the exact extraction roots or counts.
The parent generator must explicitly opt into these reconstructed inputs.

## Provenance and corrections

`manifest.json` pins the native executable, retained lite inventory, every
public reference file, readable output, and compiled descriptor set. It
distinguishes native retained names from pinned reference names and synthetic
number-based names such as `field_1`. Original source filenames, source
options, oneof names, and proto3 optional declarations remain unestablished.
Older Windows source options are discarded.

The seven v3 reference files come from `librespot-org/librespot` commit
`99b6088bf3ea028f90192676ac1a337fa4b2ed12`. Their current-native deltas include:

- SamsungSignInCredential field 3 (`id_token`) is absent in the native v3
  table and is removed from the reconstruction.
- LoginError adds `NOT_ALLOWED = 9`. Both native v3/v4 EnumEntry tables and
  the shared ten-member ordinal index verify the complete label/value map.
- HashcashSolution field 2 is `google.protobuf.Duration`, tied through its
  native parse table, Full ClassData, DescriptorTable, prototype and exact
  original standard descriptor hash.

The other three v3 enum identities and their 8 label/value pairs follow the
pinned public v3 reference; their labels are not claimed to be retained in
the current native binary. The validator checks every compiled enum field's
type identity and every supplied enum label/value, including all ten native
LoginError values. Enum fields are never replaced with int32.

## Explicit gaps

Nine v4 messages remain excluded because authoritative enum identities,
labels, or ranges are unavailable, or because they depend on those types.
This includes the full v4 LoginRequest/LoginResponse and Interaction closure.
The nested Interaction.Hint is excluded with its unresolved parent rather
than emitting a misleading partial parent. The exact message list and
reasons are in `manifest.json`.

The incomplete hazycora flat schema is not used as an authority. It omits
Duration and disagrees with native repeated interaction modes/locales and
enum types. No v4 enum ranges are invented.

`validation.json` records zero native-fact mismatches and zero unresolved
native links in the selected subset. Validator tests mutate the compiled
descriptors to prove that scalar/enum identity errors, wrong retained names,
packing changes, oneof removal, wrong Duration links, the removed Samsung
field, and a wrong NOT_ALLOWED ordinal are rejected.

This work reconstructs data models only. It does not establish a live login
session or server behavior and introduces no account-tier restrictions.
