# Original-client evidence

Target: Spotify macOS arm64 1.3.6.1921. Executable SHA-256:
`bf8772d90de830d5223f72584574f8bf04e7fc520f546c2fc1e3271cedef8fca`.

- `evidence/`: original execution and capture findings, source identities,
  substituted standard primitives and the limits of each observation.
- `fixtures/`: independently produced protocol inputs and expected outputs
  consumed by the existing checks. Credentials and account data are synthetic.
- `protobuf/`: extracted descriptors used by the protocol generator.

Synthetic DPoP keys use the explicit fixture scalar 1; their signed proofs
target `fixture.invalid`. They are public verification vectors, never session
keys. Live captures, account storage and credentials must stay in ignored
`.local/` storage. Local protocol peers live in `test/support/`.
