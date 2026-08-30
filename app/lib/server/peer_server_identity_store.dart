import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:basic_utils/basic_utils.dart';
import 'package:crypto/crypto.dart';
import 'package:fundus_server/fundus_server.dart';
import 'package:path_provider/path_provider.dart';

final class PeerServerIdentity {
  const PeerServerIdentity({
    required this.serverId,
    required this.deviceName,
    required this.certificatePem,
    required this.privateKeyPem,
    required this.certificateFingerprint,
    required this.pairedDevices,
  });

  final String serverId;
  final String deviceName;
  final String certificatePem;
  final String privateKeyPem;
  final String certificateFingerprint;
  final List<FundusPairedDevice> pairedDevices;
}

final class PeerServerPreferences {
  const PeerServerPreferences({
    this.lanEnabled = false,
    this.autoStart = false,
  });

  final bool lanEnabled;
  final bool autoStart;
}

final class PeerServerIdentityStore {
  PeerServerIdentityStore(this.directory);

  factory PeerServerIdentityStore.platformDefault() {
    final environment = Platform.environment;
    late final String base;
    if (Platform.isMacOS) {
      base =
          '${environment['HOME'] ?? Directory.current.path}'
          '${Platform.pathSeparator}Library${Platform.pathSeparator}'
          'Application Support';
    } else if (Platform.isWindows) {
      base = environment['APPDATA'] ?? Directory.current.path;
    } else {
      base =
          environment['XDG_CONFIG_HOME'] ??
          '${environment['HOME'] ?? Directory.current.path}'
              '${Platform.pathSeparator}.config';
    }
    return PeerServerIdentityStore(
      Directory(
        '$base${Platform.pathSeparator}Fundus'
        '${Platform.pathSeparator}peer-server',
      ),
    );
  }

  static Future<PeerServerIdentityStore> platformDefaultAsync() async {
    if (Platform.isAndroid || Platform.isIOS) {
      final base = await getApplicationSupportDirectory();
      return PeerServerIdentityStore(Directory('${base.path}/peer-server'));
    }
    return PeerServerIdentityStore.platformDefault();
  }

  final Directory directory;

  File get _identityFile => File('${directory.path}/identity.json');
  File get _certificateFile => File('${directory.path}/server-cert.pem');
  File get _privateKeyFile => File('${directory.path}/server-key.pem');
  File get _devicesFile => File('${directory.path}/paired-devices.json');
  File get _preferencesFile =>
      File('${directory.path}/server-preferences.json');

  Future<PeerServerIdentity> loadOrCreate() async {
    await directory.create(recursive: true);
    var serverId = await _loadServerId();
    serverId ??= 'fundus-${_randomValue(12)}';
    final deviceName = await _loadDeviceName() ?? _defaultDeviceName();
    var certificate = await _readIfPresent(_certificateFile);
    var privateKey = await _readIfPresent(_privateKeyFile);
    if (certificate == null || privateKey == null) {
      final pair = CryptoUtils.generateRSAKeyPair(keySize: 2048);
      final rsaPrivate = pair.privateKey as RSAPrivateKey;
      final rsaPublic = pair.publicKey as RSAPublicKey;
      final attributes = {'CN': 'Fundus Local Peer', 'O': 'Fundus'};
      final csr = X509Utils.generateRsaCsrPem(
        attributes,
        rsaPrivate,
        rsaPublic,
        san: const ['localhost'],
      );
      certificate = X509Utils.generateSelfSignedCertificate(
        rsaPrivate,
        csr,
        3650,
        sans: const ['localhost'],
        extKeyUsage: const [ExtendedKeyUsage.SERVER_AUTH],
        serialNumber: _randomSerial(),
      );
      privateKey = CryptoUtils.encodeRSAPrivateKeyToPem(rsaPrivate);
      await _certificateFile.writeAsString(certificate, flush: true);
      await _privateKeyFile.writeAsString(privateKey, flush: true);
      await _restrictPrivateFile(_privateKeyFile);
    }
    await _identityFile.writeAsString(
      jsonEncode({'server_id': serverId, 'device_name': deviceName}),
      flush: true,
    );
    final der = CryptoUtils.getBytesFromPEMString(certificate);
    final fingerprint = sha256.convert(der).toString();
    return PeerServerIdentity(
      serverId: serverId,
      deviceName: deviceName,
      certificatePem: certificate,
      privateKeyPem: privateKey,
      certificateFingerprint: fingerprint,
      pairedDevices: await loadPairedDevices(),
    );
  }

  Future<List<FundusPairedDevice>> loadPairedDevices() async {
    final source = await _readIfPresent(_devicesFile);
    if (source == null) return const [];
    try {
      final value = jsonDecode(source);
      if (value is! List) return const [];
      return value
          .map(FundusPairedDevice.fromJson)
          .whereType<FundusPairedDevice>()
          .toList(growable: false);
    } on FormatException {
      return const [];
    }
  }

  Future<void> savePairedDevices(List<FundusPairedDevice> devices) async {
    await directory.create(recursive: true);
    await _devicesFile.writeAsString(
      const JsonEncoder.withIndent(
        '  ',
      ).convert(devices.map((device) => device.toJson()).toList()),
      flush: true,
    );
  }

  Future<PeerServerPreferences> loadPreferences() async {
    final source = await _readIfPresent(_preferencesFile);
    if (source == null) return const PeerServerPreferences();
    try {
      final value = jsonDecode(source);
      if (value is! Map) return const PeerServerPreferences();
      return PeerServerPreferences(
        lanEnabled: value['lan_enabled'] == true,
        autoStart: value['auto_start'] == true,
      );
    } on FormatException {
      return const PeerServerPreferences();
    }
  }

  Future<void> savePreferences(PeerServerPreferences preferences) async {
    await directory.create(recursive: true);
    await _preferencesFile.writeAsString(
      jsonEncode({
        'lan_enabled': preferences.lanEnabled,
        'auto_start': preferences.autoStart,
      }),
      flush: true,
    );
  }

  Future<void> saveDeviceName(String serverId, String deviceName) async {
    await directory.create(recursive: true);
    await _identityFile.writeAsString(
      jsonEncode({'server_id': serverId, 'device_name': deviceName}),
      flush: true,
    );
  }

  Future<String?> _loadServerId() async {
    final source = await _readIfPresent(_identityFile);
    if (source == null) return null;
    try {
      final value = jsonDecode(source);
      if (value is Map && value['server_id'] is String) {
        return value['server_id'] as String;
      }
    } on FormatException {
      return null;
    }
    return null;
  }

  Future<String?> _loadDeviceName() async {
    final source = await _readIfPresent(_identityFile);
    if (source == null) return null;
    try {
      final value = jsonDecode(source);
      if (value is Map && value['device_name'] is String) {
        final name = (value['device_name'] as String).trim();
        return name.isEmpty ? null : name;
      }
    } on FormatException {
      return null;
    }
    return null;
  }

  static String _defaultDeviceName() => switch (Platform.operatingSystem) {
    'android' => 'Fundus auf Android',
    'ios' => 'Fundus auf iOS',
    'macos' => 'Fundus auf macOS',
    'windows' => 'Fundus auf Windows',
    'linux' => 'Fundus auf Linux',
    _ => 'Fundus-Gerät',
  };

  static Future<String?> _readIfPresent(File file) async {
    try {
      if (!await file.exists()) return null;
      final value = await file.readAsString();
      return value.trim().isEmpty ? null : value;
    } on FileSystemException {
      return null;
    }
  }

  static Future<void> _restrictPrivateFile(File file) async {
    if (Platform.isWindows) return;
    await Process.run('chmod', ['600', file.path]);
  }

  static String _randomValue(int byteCount) {
    final random = Random.secure();
    final bytes = List<int>.generate(byteCount, (_) => random.nextInt(256));
    return base64UrlEncode(bytes).replaceAll('=', '');
  }

  static String _randomSerial() {
    final random = Random.secure();
    return List.generate(24, (_) => random.nextInt(10)).join();
  }
}
