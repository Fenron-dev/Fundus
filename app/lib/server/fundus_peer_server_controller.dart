import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:fundus_core/fundus_core.dart';
import 'package:fundus_server/fundus_server.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

import '../diagnostics/fundus_diagnostics.dart';

final class PeerLibrarySource {
  const PeerLibrarySource({required this.path, required this.name});

  final String path;
  final String name;
}

final class PeerSharedLibraryStatus {
  const PeerSharedLibraryStatus({
    required this.name,
    required this.path,
    required this.available,
    required this.shared,
    this.libraryId,
    this.workCount,
    this.error,
  });

  final String name;
  final String path;
  final bool available;
  final bool shared;
  final String? libraryId;
  final int? workCount;
  final String? error;
}

enum PeerServerState { stopped, starting, running, stopping, failed }

final class FundusPeerServerController extends ChangeNotifier {
  FundusPeerServerController({String? serverId, String? token})
    : serverId = serverId ?? 'fundus-${_randomValue(9)}',
      _token = token ?? _randomValue(32);

  final String serverId;
  final String _token;
  final FundusLibraryRegistry _registry = FundusLibraryRegistry();
  List<PeerLibrarySource> _sources = const [];
  final Set<String> _sharedPaths = {};
  List<PeerSharedLibraryStatus> _libraries = const [];
  HttpServer? _server;
  PeerServerState _state = PeerServerState.stopped;
  String? _error;

  PeerServerState get state => _state;
  bool get isRunning => _state == PeerServerState.running;
  bool get isBusy =>
      _state == PeerServerState.starting || _state == PeerServerState.stopping;
  int? get port => _server?.port;
  Uri? get localUri =>
      port == null ? null : Uri.parse('http://127.0.0.1:$port');
  String? get error => _error;
  List<PeerLibrarySource> get sources => List.unmodifiable(_sources);
  List<PeerSharedLibraryStatus> get libraries => List.unmodifiable(_libraries);
  bool get hasSharedSources => _sources.any(
    (source) => _sharedPaths.contains(Directory(source.path).absolute.path),
  );

  Future<void> setSources(Iterable<PeerLibrarySource> sources) async {
    final previousPaths = _sources
        .map((source) => Directory(source.path).absolute.path)
        .toSet();
    final byPath = <String, PeerLibrarySource>{};
    for (final source in sources) {
      byPath[Directory(source.path).absolute.path] = source;
    }
    _sources = byPath.values.toList(growable: false);
    _sharedPaths.retainAll(byPath.keys);
    _sharedPaths.addAll(
      byPath.keys.where((path) => !previousPaths.contains(path)),
    );
    if (isRunning) {
      await stop();
      await start();
    } else {
      _libraries = [
        for (final source in _sources)
          PeerSharedLibraryStatus(
            name: source.name,
            path: source.path,
            available: _manifest(source.path).existsSync(),
            shared: _isShared(source.path),
          ),
      ];
      notifyListeners();
    }
  }

  Future<void> setLibraryShared(String path, bool shared) async {
    final normalized = Directory(path).absolute.path;
    shared ? _sharedPaths.add(normalized) : _sharedPaths.remove(normalized);
    if (isRunning) {
      await stop();
      if (hasSharedSources) await start();
      return;
    }
    _libraries = [
      for (final source in _sources)
        PeerSharedLibraryStatus(
          name: source.name,
          path: source.path,
          available: _manifest(source.path).existsSync(),
          shared: _isShared(source.path),
        ),
    ];
    notifyListeners();
  }

  Future<void> start() async {
    if (isRunning || isBusy) return;
    _state = PeerServerState.starting;
    _error = null;
    notifyListeners();
    final statuses = <PeerSharedLibraryStatus>[];
    try {
      for (final source in _sources) {
        if (!_isShared(source.path)) {
          statuses.add(
            PeerSharedLibraryStatus(
              name: source.name,
              path: source.path,
              available: _manifest(source.path).existsSync(),
              shared: false,
            ),
          );
          continue;
        }
        if (!_manifest(source.path).existsSync()) {
          statuses.add(
            PeerSharedLibraryStatus(
              name: source.name,
              path: source.path,
              available: false,
              shared: true,
              error: 'Bibliothek ist nicht verfügbar.',
            ),
          );
          continue;
        }
        try {
          final library = await FundusLibrary.open(Directory(source.path));
          _registry.register(library, name: source.name);
          statuses.add(
            PeerSharedLibraryStatus(
              name: source.name,
              path: source.path,
              available: true,
              shared: true,
              libraryId: library.manifest.libraryId,
              workCount: library.listWorks().length,
            ),
          );
        } catch (error) {
          statuses.add(
            PeerSharedLibraryStatus(
              name: source.name,
              path: source.path,
              available: false,
              shared: true,
              error: 'Bibliothek konnte nicht geöffnet werden.',
            ),
          );
        }
      }
      final handler = FundusServerHandler(
        token: _token,
        serverId: serverId,
        registry: _registry,
      );
      _server = await shelf_io.serve(
        handler.handler,
        InternetAddress.loopbackIPv4,
        0,
        shared: false,
      );
      _libraries = statuses;
      _state = PeerServerState.running;
      unawaited(
        FundusDiagnostics.instance.record('server.started', {
          'server_id': serverId,
          'library_count': statuses.where((entry) => entry.available).length,
          'port': _server?.port,
          'interface': 'loopback',
        }),
      );
    } catch (error) {
      _registry.close();
      _libraries = statuses;
      _error = _displayStartError(error);
      _state = PeerServerState.failed;
      unawaited(
        FundusDiagnostics.instance.record('server.start_failed', {
          'server_id': serverId,
          'reason': _safeErrorCode(error),
        }),
      );
    }
    notifyListeners();
  }

  Future<void> stop() async {
    if (_state == PeerServerState.stopped ||
        _state == PeerServerState.stopping) {
      return;
    }
    _state = PeerServerState.stopping;
    notifyListeners();
    await _server?.close(force: true);
    _server = null;
    _registry.close();
    _state = PeerServerState.stopped;
    _error = null;
    _libraries = [
      for (final source in _sources)
        PeerSharedLibraryStatus(
          name: source.name,
          path: source.path,
          available: _manifest(source.path).existsSync(),
          shared: _isShared(source.path),
        ),
    ];
    unawaited(
      FundusDiagnostics.instance.record('server.stopped', {
        'server_id': serverId,
      }),
    );
    notifyListeners();
  }

  @override
  void dispose() {
    final server = _server;
    _server = null;
    if (server != null) unawaited(server.close(force: true));
    _registry.close();
    super.dispose();
  }

  static File _manifest(String path) => File(
    '$path${Platform.pathSeparator}.library'
    '${Platform.pathSeparator}version.json',
  );

  bool _isShared(String path) =>
      _sharedPaths.contains(Directory(path).absolute.path);

  static String _displayStartError(Object error) {
    if (error is SocketException) {
      return Platform.isMacOS
          ? 'macOS hat das Öffnen des lokalen Server-Ports abgelehnt.'
          : 'Der lokale Server-Port konnte nicht geöffnet werden.';
    }
    return 'Server konnte nicht gestartet werden.';
  }

  static String _safeErrorCode(Object error) => switch (error) {
    SocketException(:final osError) =>
      'socket_${osError?.errorCode ?? 'unknown'}',
    FileSystemException() => 'filesystem',
    _ => error.runtimeType.toString(),
  };

  static String _randomValue(int byteCount) {
    final random = Random.secure();
    final bytes = List<int>.generate(byteCount, (_) => random.nextInt(256));
    return base64UrlEncode(bytes).replaceAll('=', '');
  }
}
