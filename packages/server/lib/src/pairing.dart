import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

final class FundusPairedDevice {
  const FundusPairedDevice({
    required this.id,
    required this.name,
    required this.tokenHash,
    required this.pairedAt,
    this.lastSeenAt,
    this.allowAdultExplicit = false,
  });

  final String id;
  final String name;
  final String tokenHash;
  final DateTime pairedAt;
  final DateTime? lastSeenAt;
  final bool allowAdultExplicit;

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'token_hash': tokenHash,
    'paired_at': pairedAt.toUtc().toIso8601String(),
    if (lastSeenAt != null)
      'last_seen_at': lastSeenAt!.toUtc().toIso8601String(),
    'allow_adult_explicit': allowAdultExplicit,
  };

  static FundusPairedDevice? fromJson(Object? value) {
    if (value is! Map) return null;
    final id = value['id'];
    final name = value['name'];
    final hash = value['token_hash'];
    final pairedAt = DateTime.tryParse('${value['paired_at'] ?? ''}');
    final lastSeenAt = DateTime.tryParse('${value['last_seen_at'] ?? ''}');
    if (id is! String ||
        name is! String ||
        hash is! String ||
        pairedAt == null) {
      return null;
    }
    return FundusPairedDevice(
      id: id,
      name: name,
      tokenHash: hash,
      pairedAt: pairedAt,
      lastSeenAt: lastSeenAt,
      allowAdultExplicit: value['allow_adult_explicit'] == true,
    );
  }
}

final class FundusPairingSession {
  const FundusPairingSession({
    required this.nonce,
    required this.pin,
    required this.expiresAt,
  });

  final String nonce;
  final String pin;
  final DateTime expiresAt;

  bool get isExpired => !DateTime.now().isBefore(expiresAt);
}

final class FundusPairingResult {
  const FundusPairingResult({required this.device, required this.token});

  final FundusPairedDevice device;
  final String token;
}

enum FundusPairingFailure { unavailable, invalid, expired, locked }

final class FundusPairingException implements Exception {
  const FundusPairingException(this.failure);

  final FundusPairingFailure failure;
}

typedef PairedDevicesChanged =
    Future<void> Function(List<FundusPairedDevice> devices);

/// Owns short-lived pairing sessions and long-lived, revocable device grants.
/// Only SHA-256 token digests are retained by the server.
final class FundusPairingAuthority {
  FundusPairingAuthority({
    Iterable<FundusPairedDevice> devices = const [],
    this.onChanged,
    Random? random,
  }) : _random = random ?? Random.secure(),
       _devices = {for (final device in devices) device.id: device};

  final Random _random;
  final PairedDevicesChanged? onChanged;
  final Map<String, FundusPairedDevice> _devices;
  FundusPairingSession? _session;
  int _failedAttempts = 0;

  List<FundusPairedDevice> get devices => List.unmodifiable(
    _devices.values.toList()..sort((a, b) => a.name.compareTo(b.name)),
  );

  FundusPairingSession? get activeSession {
    final session = _session;
    if (session == null || session.isExpired) {
      _session = null;
      return null;
    }
    return session;
  }

  FundusPairingSession begin({Duration lifetime = const Duration(minutes: 5)}) {
    final session = FundusPairingSession(
      nonce: _randomValue(18),
      pin: List.generate(6, (_) => _random.nextInt(10)).join(),
      expiresAt: DateTime.now().add(lifetime),
    );
    _failedAttempts = 0;
    _session = session;
    return session;
  }

  void cancel() {
    _session = null;
    _failedAttempts = 0;
  }

  Future<FundusPairingResult> claim({
    required String nonce,
    required String pin,
    required String deviceId,
    required String deviceName,
  }) async {
    final session = _session;
    if (session == null) {
      throw const FundusPairingException(FundusPairingFailure.unavailable);
    }
    if (session.isExpired) {
      cancel();
      throw const FundusPairingException(FundusPairingFailure.expired);
    }
    if (_failedAttempts >= 5) {
      cancel();
      throw const FundusPairingException(FundusPairingFailure.locked);
    }
    if (!_constantTimeEquals(nonce, session.nonce) ||
        !_constantTimeEquals(pin, session.pin)) {
      _failedAttempts++;
      if (_failedAttempts >= 5) _session = null;
      throw FundusPairingException(
        _failedAttempts >= 5
            ? FundusPairingFailure.locked
            : FundusPairingFailure.invalid,
      );
    }
    final normalizedId = deviceId.trim();
    final normalizedName = deviceName.trim();
    if (normalizedId.isEmpty ||
        normalizedId.length > 128 ||
        normalizedName.isEmpty ||
        normalizedName.length > 80) {
      throw const FundusPairingException(FundusPairingFailure.invalid);
    }
    final token = _randomValue(32);
    final now = DateTime.now().toUtc();
    final device = FundusPairedDevice(
      id: normalizedId,
      name: normalizedName,
      tokenHash: tokenDigest(token),
      pairedAt: now,
      lastSeenAt: now,
    );
    _devices[device.id] = device;
    cancel();
    await _notifyChanged();
    return FundusPairingResult(device: device, token: token);
  }

  bool authorize(String? bearerToken) {
    return authorizeDevice(bearerToken) != null;
  }

  /// Returns the paired device for a valid token and records recent activity.
  String? authorizeDevice(String? bearerToken) {
    if (bearerToken == null || bearerToken.isEmpty) return null;
    final digest = tokenDigest(bearerToken);
    for (final device in _devices.values) {
      if (!_constantTimeEquals(digest, device.tokenHash)) continue;
      _markSeen(device);
      return device.id;
    }
    return null;
  }

  void _markSeen(FundusPairedDevice device) {
    final now = DateTime.now().toUtc();
    final previous = device.lastSeenAt;
    if (previous != null &&
        now.difference(previous) < const Duration(seconds: 10)) {
      return;
    }
    _devices[device.id] = FundusPairedDevice(
      id: device.id,
      name: device.name,
      tokenHash: device.tokenHash,
      pairedAt: device.pairedAt,
      lastSeenAt: now,
      allowAdultExplicit: device.allowAdultExplicit,
    );
    final callback = onChanged;
    if (callback != null) unawaited(callback(devices));
  }

  Future<void> revoke(String deviceId) async {
    if (_devices.remove(deviceId) != null) await _notifyChanged();
  }

  Future<void> rename(String deviceId, String name) async {
    final current = _devices[deviceId];
    final normalized = name.trim();
    if (current == null || normalized.isEmpty || normalized.length > 80) return;
    _devices[deviceId] = FundusPairedDevice(
      id: current.id,
      name: normalized,
      tokenHash: current.tokenHash,
      pairedAt: current.pairedAt,
      lastSeenAt: current.lastSeenAt,
      allowAdultExplicit: current.allowAdultExplicit,
    );
    await _notifyChanged();
  }

  Future<void> setAdultExplicitAllowed(String deviceId, bool allowed) async {
    final current = _devices[deviceId];
    if (current == null || current.allowAdultExplicit == allowed) return;
    _devices[deviceId] = FundusPairedDevice(
      id: current.id,
      name: current.name,
      tokenHash: current.tokenHash,
      pairedAt: current.pairedAt,
      lastSeenAt: current.lastSeenAt,
      allowAdultExplicit: allowed,
    );
    await _notifyChanged();
  }

  bool adultExplicitAllowed(String deviceId) =>
      _devices[deviceId]?.allowAdultExplicit ?? false;

  Future<void> _notifyChanged() async {
    final callback = onChanged;
    if (callback != null) await callback(devices);
  }

  String _randomValue(int byteCount) {
    final bytes = List<int>.generate(byteCount, (_) => _random.nextInt(256));
    return base64UrlEncode(bytes).replaceAll('=', '');
  }

  static String tokenDigest(String token) =>
      sha256.convert(utf8.encode(token)).toString();

  static bool _constantTimeEquals(String actual, String expected) {
    final left = utf8.encode(actual);
    final right = utf8.encode(expected);
    var difference = left.length ^ right.length;
    final length = max(left.length, right.length);
    for (var index = 0; index < length; index++) {
      difference |=
          (index < left.length ? left[index] : 0) ^
          (index < right.length ? right[index] : 0);
    }
    return difference == 0;
  }
}
