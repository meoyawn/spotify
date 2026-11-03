// GENERATED static source translation; source SHA256 bf8772d90de830d5223f72584574f8bf04e7fc520f546c2fc1e3271cedef8fca
part of '../native_playplay_unwrap.dart';
extension _Page101c85 on _PlayPlayMath {
  int step101c85(int budget) { switch (n >>> 8) {
    case 16894047: return block101c85f(budget);
    default: throw StateError("Missing lifted block $n");
  } }
  int block101c85f(int budget) { final start = n, limit = n + (budget << 2); switch (n) {
    at_101c85fe8: case 4324876264: { if (limit == 4324876264) { n = 4324876264; throw StateError("Original arithmetic control flow exceeded its bound"); } final at = r[1]; r[9] = (m.load(at, 4)) & 0xffffffff; r[11] = (m.load((at + 4), 4)) & 0xffffffff; continue at_101c85fec; }
    at_101c85fec: case 4324876268: { if (limit == 4324876268) { n = 4324876268; throw StateError("Original arithmetic control flow exceeded its bound"); } final at = (r[1] + 16); r[16] = (m.load(at, 4)) & 0xffffffff; r[17] = (m.load((at + 4), 4)) & 0xffffffff; continue at_101c85ff0; }
    at_101c85ff0: case 4324876272: { if (limit == 4324876272) { n = 4324876272; throw StateError("Original arithmetic control flow exceeded its bound"); } final at = (r[1] + 8); r[14] = (m.load(at, 4)) & 0xffffffff; r[15] = (m.load((at + 4), 4)) & 0xffffffff; continue at_101c85ff4; }
    at_101c85ff4: case 4324876276: { if (limit == 4324876276) { n = 4324876276; throw StateError("Original arithmetic control flow exceeded its bound"); } r[8] = (48573) & 0xffffffff; continue at_101c85ff8; }
    at_101c85ff8: case 4324876280: { if (limit == 4324876280) { n = 4324876280; throw StateError("Original arithmetic control flow exceeded its bound"); } r[8] = (((r[8] & 0xffffffff) & ~0xffff0000) | 0xc92d0000) & 0xffffffff; continue at_101c85ffc; }
    at_101c85ffc: case 4324876284: { if (limit == 4324876284) { n = 4324876284; throw StateError("Original arithmetic control flow exceeded its bound"); } r[10] = (r[9] & 0xffffffff) * (r[8] & 0xffffffff); n = 4324876288; return (4324876288 - start) >>> 2; }
    default: throw StateError("Missing lifted block $n");
  } }
}
