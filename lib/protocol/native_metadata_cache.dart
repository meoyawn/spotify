/// Positive-success subset of original10060caa0/1005f6e04. A nonzero entity
/// TTL replaces the provider TTL. Do not invent the owner's configured minimum.
/// The stored deadline is whole UTC epoch seconds; equality remains fresh.
int? nativeMetadataExpiryMicroseconds({required int providerTtlSeconds,
    required int entityTtlSeconds, required int nowMicroseconds}) {
  final ttl = entityTtlSeconds == 0 ? providerTtlSeconds : entityTtlSeconds;
  if (ttl <= 0) return null;
  final seconds = ttl > 7776000 ? 7776000 : ttl;
  return ((nowMicroseconds + seconds * Duration.microsecondsPerSecond) ~/
    Duration.microsecondsPerSecond) * Duration.microsecondsPerSecond;
}
