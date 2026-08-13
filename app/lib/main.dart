import 'dart:async';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fundus_core/fundus_core.dart';
import 'package:media_kit/media_kit.dart';

import 'diagnostics/fundus_diagnostics.dart';
import 'library/android_storage_access.dart';
import 'library/recent_library_store.dart';
import 'library/security_scoped_bookmarks.dart';
import 'playback/fundus_player_controller.dart';
import 'playback/playback_conflict_settings.dart';
import 'playback/playlist_session_conflict.dart';
import 'playback/playback_sleep_timer_button.dart';
import 'playback/fundus_system_media_session.dart';
import 'server/fundus_peer_server_controller.dart';
import 'server/fundus_peer_discovery.dart';
import 'server/fundus_offline_store.dart';
import 'server/fundus_remote_client.dart';
import 'server/remote_servers_view.dart';
import 'server/server_settings.dart';

typedef WorkPlaybackCallback =
    Future<void> Function(
      LibraryWorkSummary work, {
      String? startFileId,
      Duration? startPosition,
    });
typedef PlaylistPlaybackCallback = Future<void> Function(String playlistId);
typedef MissingWorkDeleteCallback =
    Future<void> Function(LibraryWorkSummary work);
typedef WorkMetadataChangedCallback = void Function(LibraryWorkSummary work);

final class _RemoteLibraryChoice {
  const _RemoteLibraryChoice({
    required this.server,
    required this.library,
    required this.reachable,
    required this.offlineCount,
  });

  final FundusRemoteServer server;
  final FundusRemoteLibraryReference library;
  final bool reachable;
  final int offlineCount;
}

String _formatSequence(double value) => value == value.roundToDouble()
    ? value.toInt().toString()
    : value.toString().replaceAll('.', ',');

String _displayLanguage(String? language) {
  if (language == null || language.trim().isEmpty) return '—';
  final normalized = language.toLowerCase().replaceAll('_', '-');
  return switch (normalized.split('-').first) {
    'de' || 'deu' || 'ger' => 'Deutsch',
    'en' || 'eng' => 'Englisch',
    'fr' || 'fra' || 'fre' => 'Französisch',
    'es' || 'spa' => 'Spanisch',
    'it' || 'ita' => 'Italienisch',
    'ja' || 'jpn' => 'Japanisch',
    _ => language,
  };
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  await FundusSystemMediaSession.instance.initialize();
  runApp(const FundusApp());
}

class FundusApp extends StatefulWidget {
  const FundusApp({super.key, this.initialWorks});

  /// Ermöglicht Widgettests und eingebetteten Ansichten einen Start ohne
  /// nativen Ordnerdialog. Die reguläre App startet mit der Bibliotheksauswahl.
  final List<LibraryWorkSummary>? initialWorks;

  @override
  State<FundusApp> createState() => _FundusAppState();
}

class _FundusAppState extends State<FundusApp> {
  final _navigatorKey = GlobalKey<NavigatorState>();
  ThemeMode _themeMode = ThemeMode.dark;
  FundusLibrary? _library;
  List<LibraryWorkSummary>? _works;
  LibraryIndexEvent? _indexEvent;
  FundusPlayerController? _player;
  String? _error;
  bool _busy = false;
  late RecentLibraryStore _recentStore;
  late final Future<void> _recentStoreReady;
  final _remoteStore = FundusRemoteServerStore();
  final _remoteClient = const FundusRemoteClient();
  FundusOfflineStore _offlineStore = FundusOfflineStore();
  final _peerDiscovery = FundusPeerDiscovery();
  late final FundusPeerServerController _peerServer;
  List<RecentLibraryEntry> _recentLibraries = const [];
  List<_RemoteLibraryChoice> _remoteLibraries = const [];
  List<FundusOfflineWork> _offlineWorks = const [];
  bool _loadingRemoteLibraries = false;
  late final AppLifecycleListener _lifecycleListener;

  @override
  void initState() {
    super.initState();
    _peerServer = FundusPeerServerController();
    _recentStoreReady = _initializeRecentStore();
    _works = widget.initialWorks;
    if (widget.initialWorks == null) {
      unawaited(_peerServer.initialize());
      unawaited(_loadRemoteLibraries());
    }
    _lifecycleListener = AppLifecycleListener(
      onResume: () => unawaited(_loadRemoteLibraries()),
      onInactive: () => unawaited(_player?.persist()),
      onHide: () => unawaited(_player?.persist()),
      onPause: () => unawaited(_player?.persist()),
      onExitRequested: () async {
        await _player?.persist();
        return AppExitResponse.exit;
      },
    );
  }

  Future<void> _initializeRecentStore() async {
    final androidRoot = await AndroidStorageAccess.storageRoot();
    _recentStore = RecentLibraryStore.platformDefault(
      androidStorageRoot: androidRoot,
    );
    if (widget.initialWorks == null) await _loadRecentLibraries();
  }

  @override
  void dispose() {
    _lifecycleListener.dispose();
    _player?.dispose();
    _library?.close();
    _peerServer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: _navigatorKey,
      title: 'Fundus',
      debugShowCheckedModeBanner: false,
      themeMode: _themeMode,
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      home: _works == null
          ? _LibraryWelcome(
              busy: _busy,
              error: _error,
              onCreate: () => _chooseLibrary(create: true),
              onOpen: () => _chooseLibrary(create: false),
              recentLibraries: _recentLibraries,
              onOpenRecent: _openRecentLibrary,
              remoteLibraries: _remoteLibraries,
              onOpenRemote: _openRemoteLibrary,
              offlineWorks: _offlineWorks,
              onOpenOffline: _openOfflineMedia,
              onToggleTheme: _toggleTheme,
              peerServer: _peerServer,
              onOpenServerSettings: _openServerSettings,
            )
          : LibraryShell(
              works: _works!,
              library: _library,
              libraryName: _library?.root.path
                  .split(Platform.pathSeparator)
                  .last,
              indexEvent: _indexEvent,
              onRescan: _library == null || _busy ? null : _scan,
              onClose: _library == null ? null : _closeLibrary,
              player: _player,
              onPlay: _library == null ? null : _startPlayback,
              onPlayPlaylist: _library == null ? null : _startPlaylist,
              onDeleteMissingWork: _library == null ? null : _deleteMissingWork,
              onMetadataChanged: (work) => setState(() {
                _works = _library?.listWorks(includeMissing: true) ?? _works;
              }),
              onExportDiagnostics: _library == null ? null : _exportDiagnostics,
              onToggleTheme: _toggleTheme,
              themeMode: _themeMode,
              onThemeModeChanged: (mode) => setState(() => _themeMode = mode),
              peerServer: _peerServer,
              offlineStore: _offlineStore,
              offlineWorks: _offlineWorks,
              onOpenDownloads: _openOfflineMedia,
            ),
    );
  }

  void _toggleTheme() => setState(() {
    _themeMode = _themeMode == ThemeMode.dark
        ? ThemeMode.light
        : ThemeMode.dark;
  });

  Future<void> _chooseLibrary({required bool create}) async {
    if (!await _ensureAndroidLibraryAccess()) return;
    final path = await FilePicker.getDirectoryPath(
      dialogTitle: create
          ? 'Ordner für die Fundus-Bibliothek wählen'
          : 'Fundus-Bibliothek öffnen',
    );
    if (path == null || !mounted) return;
    final bookmark = await SecurityScopedBookmarks.create(path);
    await _openLibraryPath(path, create: create, securityBookmark: bookmark);
  }

  Future<void> _openRecentLibrary(RecentLibraryEntry entry) async {
    if (!await _ensureAndroidLibraryAccess()) return;
    var bookmark = entry.securityBookmark;
    String? resolvedPath;
    try {
      resolvedPath = await SecurityScopedBookmarks.startAccess(bookmark);
    } on PlatformException {
      resolvedPath = null;
    } on MissingPluginException {
      resolvedPath = null;
    }
    if (Platform.isMacOS && resolvedPath == null) {
      final selected = await FilePicker.getDirectoryPath(
        dialogTitle: 'Zugriff auf „${entry.name}“ erneut erlauben',
        initialDirectory: entry.path,
      );
      if (selected == null || !mounted) return;
      resolvedPath = selected;
      bookmark = await SecurityScopedBookmarks.create(selected);
    }
    final opened = await _openLibraryPath(
      resolvedPath ?? entry.path,
      create: false,
      securityBookmark: bookmark,
      showError: !Platform.isAndroid,
    );
    if (opened || !Platform.isAndroid || !mounted) return;
    final selected = await FilePicker.getDirectoryPath(
      dialogTitle: 'Zugriff auf „${entry.name}“ erneut erlauben',
    );
    if (selected == null || !mounted) return;
    await _openLibraryPath(selected, create: false);
  }

  Future<bool> _ensureAndroidLibraryAccess() async {
    if (!Platform.isAndroid || await AndroidStorageAccess.isGranted()) {
      return true;
    }
    if (!mounted) return false;
    final dialogContext = _navigatorKey.currentContext;
    if (dialogContext == null || !dialogContext.mounted) {
      setState(() => _error = 'Die Bibliotheksauswahl ist noch nicht bereit.');
      return false;
    }
    final openSettings =
        await showDialog<bool>(
          context: dialogContext,
          builder: (context) => AlertDialog(
            title: const Text('Bibliothekszugriff erlauben'),
            content: const Text(
              'Fundus verwaltet portable Bibliotheken mit Mediendateien, '
              'Covern, Metadaten und einer Datenbank direkt im gewählten '
              'Ordner. Android benötigt dafür die Systemfreigabe „Zugriff '
              'auf alle Dateien“. Fundus verwendet sie ausschließlich für '
              'die Bibliotheken, die du selbst öffnest.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Abbrechen'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Einstellungen öffnen'),
              ),
            ],
          ),
        ) ??
        false;
    if (!openSettings) return false;
    final granted = await AndroidStorageAccess.request();
    if (granted) {
      await _recentStoreReady;
      await _loadRecentLibraries();
    } else if (mounted) {
      setState(() {
        _error =
            'Der Bibliothekszugriff wurde nicht freigegeben. Bitte '
            'aktiviere in den Android-Einstellungen „Zugriff auf alle '
            'Dateien“ für Fundus.';
      });
    }
    return granted;
  }

  Future<bool> _openLibraryPath(
    String path, {
    required bool create,
    String? securityBookmark,
    bool showError = true,
  }) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final library = create
          ? await FundusLibrary.create(Directory(path))
          : await FundusLibrary.open(Directory(path));
      await _stopPlayer();
      _library?.close();
      _library = library;
      _offlineStore = FundusOfflineStore.forLibrary(library.root);
      _offlineWorks = await _offlineStore.listAll();
      await FundusDiagnostics.instance.configure(library.root);
      await FundusDiagnostics.instance.record('library.opened', {
        'library_id': library.manifest.libraryId,
        'create': create,
      });
      _works = library.listWorks(includeMissing: true);
      await _recentStoreReady;
      _recentLibraries = await _recentStore.remember(
        path,
        _recentLibraries,
        securityBookmark: securityBookmark,
      );
      await _syncPeerSources();
      if (mounted) setState(() {});
      await _scan();
      return true;
    } catch (error) {
      if (mounted && showError) {
        setState(() => _error = _displayLibraryError(error));
      }
      return false;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  static String _displayLibraryError(Object error) {
    if (error is FileSystemException || error is PathAccessException) {
      return 'Fundus hat keinen Zugriff auf diese Bibliothek. Bitte den '
          'Ordner erneut auswählen und den Zugriff bestätigen.';
    }
    return error.toString();
  }

  Future<void> _loadRecentLibraries() async {
    var entries = await _recentStore.load();
    if (Platform.isMacOS) {
      final resolved = <RecentLibraryEntry>[];
      for (final entry in entries) {
        String? path;
        try {
          path = await SecurityScopedBookmarks.startAccess(
            entry.securityBookmark,
          );
        } on PlatformException {
          path = null;
        } on MissingPluginException {
          path = null;
        }
        resolved.add(
          path == null
              ? entry
              : RecentLibraryEntry(
                  path: path,
                  lastOpenedAt: entry.lastOpenedAt,
                  securityBookmark: entry.securityBookmark,
                ),
        );
      }
      entries = resolved;
    }
    _recentLibraries = entries;
    await _syncPeerSources();
    if (mounted) setState(() {});
  }

  Future<void> _loadRemoteLibraries() async {
    if (_loadingRemoteLibraries) return;
    _loadingRemoteLibraries = true;
    try {
      var servers = await _remoteStore.load();
      var references = await _remoteStore.loadLibraryReferences();
      final offline = await _offlineStore.listAll();
      final reachable = <String>{};
      if (mounted) {
        setState(() {
          _offlineWorks = offline;
          _remoteLibraries = _remoteChoices(
            servers,
            references,
            reachable,
            offline,
          );
        });
      }
      servers = await _peerDiscovery.relocate(servers);
      await _remoteStore.save(servers);
      await _syncOfflineProgress(servers);
      await Future.wait([
        for (final server in servers)
          () async {
            try {
              final libraries = await _remoteClient.libraries(server);
              await _remoteStore.rememberLibraries(server, libraries);
              reachable.add(server.id);
            } catch (_) {
              // Gespeicherte Metadaten bleiben für Offline-Inhalte sichtbar.
            }
          }(),
      ]);
      references = await _remoteStore.loadLibraryReferences();
      if (!mounted) return;
      setState(() {
        _offlineWorks = offline;
        _remoteLibraries = _remoteChoices(
          servers,
          references,
          reachable,
          offline,
        );
      });
    } catch (_) {
      // Die lokale Bibliotheksauswahl bleibt auch ohne Netzwerk verfügbar.
    } finally {
      _loadingRemoteLibraries = false;
    }
  }

  static List<_RemoteLibraryChoice> _remoteChoices(
    List<FundusRemoteServer> servers,
    List<FundusRemoteLibraryReference> references,
    Set<String> reachable,
    List<FundusOfflineWork> offline,
  ) {
    final byId = {for (final server in servers) server.id: server};
    return [
      for (final reference in references)
        if (byId[reference.serverId] case final server?)
          _RemoteLibraryChoice(
            server: server,
            library: reference,
            reachable: reachable.contains(server.id),
            offlineCount: offline
                .where(
                  (work) =>
                      work.serverId == server.id &&
                      work.libraryId == reference.libraryId,
                )
                .length,
          ),
    ]..sort((left, right) {
      final byServer = left.server.name.toLowerCase().compareTo(
        right.server.name.toLowerCase(),
      );
      return byServer != 0
          ? byServer
          : left.library.name.toLowerCase().compareTo(
              right.library.name.toLowerCase(),
            );
    });
  }

  Future<void> _syncOfflineProgress(List<FundusRemoteServer> servers) async {
    final byId = {for (final server in servers) server.id: server};
    final deviceId = await _remoteStore.deviceId();
    for (final pending in await _offlineStore.pendingProgress()) {
      final server = byId[pending.serverId];
      if (server == null) continue;
      try {
        await _remoteClient.saveProgress(
          server,
          libraryId: pending.libraryId,
          workId: pending.workId,
          fileId: pending.fileId,
          position: pending.position,
          duration: null,
          finished: pending.finished,
          deviceId: deviceId,
          operationId: pending.operationId,
        );
        await _offlineStore.markProgressSynced(pending);
      } catch (_) {
        // Bleibt bis zum nächsten App-/Netzwerkstart in der lokalen Queue.
      }
    }
  }

  Future<void> _openRemoteLibrary(_RemoteLibraryChoice choice) async {
    final dialogContext = _navigatorKey.currentContext;
    if (dialogContext == null) return;
    await showFundusRemoteServers(
      dialogContext,
      initialServerId: choice.server.id,
      initialLibraryId: choice.library.libraryId,
      peerServer: _peerServer,
      offlineStore: _offlineStore,
    );
    await _loadRemoteLibraries();
  }

  Future<void> _openOfflineMedia() async {
    final dialogContext = _navigatorKey.currentContext;
    if (dialogContext == null) return;
    await showFundusRemoteServers(
      dialogContext,
      peerServer: _peerServer,
      offlineStore: _offlineStore,
    );
    await _loadRemoteLibraries();
  }

  Future<void> _openServerSettings() async {
    final dialogContext = _navigatorKey.currentContext;
    if (dialogContext == null) return;
    await showFundusServerSettings(
      dialogContext,
      _peerServer,
      offlineStore: _offlineStore,
      themeMode: _themeMode,
      onThemeModeChanged: (mode) => setState(() => _themeMode = mode),
      onExportDiagnostics: _library == null ? null : _exportDiagnostics,
    );
    await _loadRemoteLibraries();
  }

  Future<void> _syncPeerSources() => _peerServer.setSources(
    _recentLibraries.map(
      (entry) => PeerLibrarySource(path: entry.path, name: entry.name),
    ),
  );

  Future<void> _scan() async {
    final library = _library;
    if (library == null || library.isReadOnly) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await FundusDiagnostics.instance.record('library.scan_started');
      await for (final event in library.index()) {
        if (!mounted) return;
        setState(() => _indexEvent = event);
      }
      if (mounted) {
        setState(() => _works = library.listWorks(includeMissing: true));
      }
      await _recordAudioCompatibility(library);
      await FundusDiagnostics.instance.record('library.scan_completed', {
        'work_count': library.listWorks().length,
        'file_count': _indexEvent?.fileCount,
      });
    } catch (error) {
      await FundusDiagnostics.instance.record('library.scan_failed', {
        'error': error.toString(),
      });
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _recordAudioCompatibility(FundusLibrary library) async {
    var checkedFiles = 0;
    final attention = <Map<String, Object?>>[];
    for (final work in library.listWorks()) {
      for (final track in library.playbackTracks(work.id)) {
        final metadata = track.audioMetadata;
        if (metadata == null) continue;
        checkedFiles++;
        final assessment = metadata.assess(AudioPlaybackTarget.android);
        if (assessment.status == AudioCompatibilityStatus.compatible) continue;
        attention.add({
          'work_id': work.id,
          'file_id': track.fileId,
          'target': 'android',
          'status': assessment.status.name,
          'container': metadata.container,
          'codec': metadata.codec,
          'profile': metadata.profile,
          'channels': metadata.channels,
          'sample_rate_hz': metadata.sampleRateHz,
          'reason': assessment.reason,
        });
      }
    }
    await FundusDiagnostics.instance.record('library.audio_compatibility', {
      'checked_file_count': checkedFiles,
      'attention_count': attention.length,
      'attention': attention,
    });
  }

  Future<void> _exportDiagnostics() async {
    final source = FundusDiagnostics.instance.file;
    if (source == null || !await source.exists()) return;
    final now = DateTime.now();
    final timestamp =
        '${now.year.toString().padLeft(4, '0')}'
        '${now.month.toString().padLeft(2, '0')}'
        '${now.day.toString().padLeft(2, '0')}-'
        '${now.hour.toString().padLeft(2, '0')}'
        '${now.minute.toString().padLeft(2, '0')}'
        '${now.second.toString().padLeft(2, '0')}';
    final destination = await FilePicker.saveFile(
      dialogTitle: 'Fundus-Diagnoseprotokoll exportieren',
      fileName: 'fundus-diagnostics-$timestamp.log',
      bytes: await source.readAsBytes(),
    );
    if (destination != null) {
      await FundusDiagnostics.instance.record('diagnostics.exported');
    }
  }

  Future<void> _startPlayback(
    LibraryWorkSummary work, {
    String? startFileId,
    Duration? startPosition,
  }) async {
    final library = _library;
    if (library == null) return;
    final player =
        _player ??
        FundusPlayerController(
          deviceId: _peerServer.serverId,
          deviceName: _peerServer.deviceName,
          deviceNameForId: _peerServer.displayNameForDevice,
          onConflict: (conflict) {
            final context = _navigatorKey.currentContext;
            return context == null
                ? Future.value(PlaybackConflictChoice.keepCurrent)
                : resolvePlaybackConflict(context, conflict);
          },
          onPlaylistConflict: (conflict) {
            final context = _navigatorKey.currentContext;
            return context == null
                ? Future.value(PlaylistSessionChoice.keepSession)
                : resolvePlaylistSessionConflict(context, conflict);
          },
        );
    if (_player == null) setState(() => _player = player);
    await player.open(
      library,
      work,
      startFileId: startFileId,
      startPosition: startPosition,
    );
  }

  Future<void> _startPlaylist(String playlistId) async {
    final library = _library;
    if (library == null) return;
    final player =
        _player ??
        FundusPlayerController(
          deviceId: _peerServer.serverId,
          deviceName: _peerServer.deviceName,
          deviceNameForId: _peerServer.displayNameForDevice,
          onConflict: (conflict) {
            final context = _navigatorKey.currentContext;
            return context == null
                ? Future.value(PlaybackConflictChoice.keepCurrent)
                : resolvePlaybackConflict(context, conflict);
          },
          onPlaylistConflict: (conflict) {
            final context = _navigatorKey.currentContext;
            return context == null
                ? Future.value(PlaylistSessionChoice.keepSession)
                : resolvePlaylistSessionConflict(context, conflict);
          },
        );
    if (_player == null) setState(() => _player = player);
    await player.loadSavedPlaylist(playlistId, library: library);
  }

  Future<void> _stopPlayer() async {
    final player = _player;
    if (player == null) return;
    await player.close();
    player.dispose();
    _player = null;
  }

  Future<void> _deleteMissingWork(LibraryWorkSummary work) async {
    final library = _library;
    if (library == null || work.available) return;
    library.deleteMissingWork(work.id);
    if (!mounted) return;
    setState(() => _works = library.listWorks(includeMissing: true));
  }

  Future<void> _closeLibrary() async {
    await _stopPlayer();
    _library?.close();
    if (!mounted) return;
    setState(() {
      _library = null;
      _works = null;
      _indexEvent = null;
      _error = null;
    });
  }

  ThemeData _theme(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final scheme = ColorScheme.fromSeed(
      seedColor: dark ? const Color(0xff9184d9) : const Color(0xff6e62b0),
      brightness: brightness,
      surface: dark ? const Color(0xff232532) : const Color(0xfffbfaff),
    );
    return ThemeData(
      colorScheme: scheme,
      scaffoldBackgroundColor: dark
          ? const Color(0xff161826)
          : const Color(0xfff1f0f8),
      useMaterial3: true,
      visualDensity: VisualDensity.compact,
      cardTheme: CardThemeData(
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(color: scheme.outlineVariant),
        ),
      ),
    );
  }
}

class _LibraryWelcome extends StatelessWidget {
  const _LibraryWelcome({
    required this.busy,
    required this.error,
    required this.onCreate,
    required this.onOpen,
    required this.recentLibraries,
    required this.onOpenRecent,
    required this.remoteLibraries,
    required this.onOpenRemote,
    required this.offlineWorks,
    required this.onOpenOffline,
    required this.onToggleTheme,
    required this.peerServer,
    required this.onOpenServerSettings,
  });

  final bool busy;
  final String? error;
  final VoidCallback onCreate;
  final VoidCallback onOpen;
  final List<RecentLibraryEntry> recentLibraries;
  final ValueChanged<RecentLibraryEntry> onOpenRecent;
  final List<_RemoteLibraryChoice> remoteLibraries;
  final ValueChanged<_RemoteLibraryChoice> onOpenRemote;
  final List<FundusOfflineWork> offlineWorks;
  final VoidCallback onOpenOffline;
  final VoidCallback onToggleTheme;
  final FundusPeerServerController peerServer;
  final VoidCallback onOpenServerSettings;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Fundus'),
        actions: [
          IconButton(
            onPressed: onOpenServerSettings,
            tooltip: 'Server & Freigaben',
            icon: const Icon(Icons.lan_outlined),
          ),
          IconButton(
            onPressed: onToggleTheme,
            tooltip: 'Theme wechseln',
            icon: const Icon(Icons.contrast),
          ),
        ],
      ),
      body: Center(
        child: SingleChildScrollView(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.video_library_outlined,
                    size: 72,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(height: 24),
                  Text(
                    'Deine Medien. Deine Daten.',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineMedium,
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Öffne eine portable Fundus-Bibliothek oder lege sie direkt in deinem Medienordner an.',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 28),
                  Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      FilledButton.icon(
                        onPressed: busy ? null : onCreate,
                        icon: const Icon(Icons.create_new_folder_outlined),
                        label: const Text('Bibliothek anlegen'),
                      ),
                      OutlinedButton.icon(
                        onPressed: busy ? null : onOpen,
                        icon: const Icon(Icons.folder_open),
                        label: const Text('Bibliothek öffnen'),
                      ),
                    ],
                  ),
                  if (recentLibraries.isNotEmpty) ...[
                    const SizedBox(height: 28),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'Zuletzt verwendete Bibliotheken',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Card(
                      clipBehavior: Clip.antiAlias,
                      child: Column(
                        children: [
                          for (
                            var index = 0;
                            index < recentLibraries.length;
                            index++
                          ) ...[
                            _RecentLibraryTile(
                              entry: recentLibraries[index],
                              onTap: busy
                                  ? null
                                  : () => onOpenRecent(recentLibraries[index]),
                            ),
                            if (index < recentLibraries.length - 1)
                              const Divider(height: 1),
                          ],
                        ],
                      ),
                    ),
                  ],
                  if (remoteLibraries.isNotEmpty) ...[
                    const SizedBox(height: 24),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'Bibliotheken gekoppelter Geräte',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Card(
                      clipBehavior: Clip.antiAlias,
                      child: Column(
                        children: [
                          for (
                            var index = 0;
                            index < remoteLibraries.length;
                            index++
                          ) ...[
                            _RemoteLibraryTile(
                              choice: remoteLibraries[index],
                              onTap: busy
                                  ? null
                                  : () => onOpenRemote(remoteLibraries[index]),
                            ),
                            if (index < remoteLibraries.length - 1)
                              const Divider(height: 1),
                          ],
                        ],
                      ),
                    ),
                  ],
                  if (offlineWorks.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    Card(
                      clipBehavior: Clip.antiAlias,
                      child: ListTile(
                        enabled: !busy,
                        onTap: busy ? null : onOpenOffline,
                        leading: const Icon(Icons.download_done),
                        title: const Text('Offline auf diesem Gerät'),
                        subtitle: Text(
                          '${offlineWorks.length} heruntergeladene Medien',
                        ),
                        trailing: const Icon(Icons.chevron_right),
                      ),
                    ),
                  ],
                  if (busy) ...[
                    const SizedBox(height: 24),
                    const LinearProgressIndicator(),
                  ],
                  if (error != null) ...[
                    const SizedBox(height: 20),
                    Text(
                      error!,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _RemoteLibraryTile extends StatelessWidget {
  const _RemoteLibraryTile({required this.choice, required this.onTap});

  final _RemoteLibraryChoice choice;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final offlineOnly = !choice.reachable && choice.offlineCount > 0;
    return ListTile(
      enabled: onTap != null,
      onTap: onTap,
      leading: Icon(
        Icons.circle,
        size: 12,
        color: choice.reachable
            ? Colors.green
            : offlineOnly
            ? Colors.orange
            : Theme.of(context).colorScheme.error,
      ),
      title: Text(choice.library.name),
      subtitle: Text(choice.server.name),
      trailing: Text(
        choice.reachable
            ? '${choice.library.workCount} Werk(e)'
            : offlineOnly
            ? '${choice.offlineCount} offline'
            : 'Nicht erreichbar',
      ),
    );
  }
}

class _RecentLibraryTile extends StatelessWidget {
  const _RecentLibraryTile({required this.entry, required this.onTap});

  final RecentLibraryEntry entry;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final available = entry.available;
    final canAttempt = available || Platform.isMacOS;
    return ListTile(
      enabled: canAttempt && onTap != null,
      onTap: canAttempt ? onTap : null,
      leading: Icon(
        Icons.circle,
        size: 12,
        color: available
            ? Colors.green
            : Platform.isMacOS
            ? Colors.orange
            : Theme.of(context).colorScheme.error,
      ),
      title: Text(entry.name),
      subtitle: Text(entry.path, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: Text(
        available
            ? 'Verfügbar'
            : Platform.isMacOS
            ? 'Zugriff erneuern'
            : 'Nicht verfügbar',
      ),
    );
  }
}

class LibraryShell extends StatefulWidget {
  const LibraryShell({
    super.key,
    required this.works,
    required this.onToggleTheme,
    this.themeMode = ThemeMode.dark,
    this.onThemeModeChanged,
    this.library,
    this.libraryName,
    this.indexEvent,
    this.onRescan,
    this.onClose,
    this.player,
    this.onPlay,
    this.onPlayPlaylist,
    this.onDeleteMissingWork,
    this.onMetadataChanged,
    this.onExportDiagnostics,
    this.peerServer,
    this.offlineStore,
    this.offlineWorks = const [],
    this.onOpenDownloads,
  });

  final List<LibraryWorkSummary> works;
  final FundusLibrary? library;
  final VoidCallback onToggleTheme;
  final ThemeMode themeMode;
  final ValueChanged<ThemeMode>? onThemeModeChanged;
  final String? libraryName;
  final LibraryIndexEvent? indexEvent;
  final VoidCallback? onRescan;
  final VoidCallback? onClose;
  final FundusPlayerController? player;
  final WorkPlaybackCallback? onPlay;
  final PlaylistPlaybackCallback? onPlayPlaylist;
  final MissingWorkDeleteCallback? onDeleteMissingWork;
  final WorkMetadataChangedCallback? onMetadataChanged;
  final VoidCallback? onExportDiagnostics;
  final FundusPeerServerController? peerServer;
  final FundusOfflineStore? offlineStore;
  final List<FundusOfflineWork> offlineWorks;
  final VoidCallback? onOpenDownloads;

  @override
  State<LibraryShell> createState() => _LibraryShellState();
}

class _LibraryShellState extends State<LibraryShell> {
  final _searchController = SearchController();
  _LibrarySection _section = _LibrarySection.library;
  int _selectedIndex = 0;
  int _mobileDestination = 0;
  LibraryWorkQuery _query = const LibraryWorkQuery();
  _LibraryLayout _layout = _LibraryLayout.grid;
  _LibraryGrouping _grouping = _LibraryGrouping.books;
  String? _selectedAuthor;
  String? _selectedNarrator;
  String? _selectedSeries;
  bool _detailPaneVisible = true;
  bool _playerExpanded = false;
  LibraryWorkSummary? _inlineDetailWork;
  double _leftPaneWidth = 236;
  double _detailPaneWidth = 368;
  String? _playlistTypeFilter;
  List<LibrarySavedView> _savedViews = const [];

  @override
  void initState() {
    super.initState();
    unawaited(_loadSavedViews());
  }

  @override
  void didUpdateWidget(covariant LibraryShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.library != widget.library) unawaited(_loadSavedViews());
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  List<LibraryWorkSummary> get _visibleWorks =>
      LibraryWorkSearch.apply(widget.works, _query);

  bool get _showingGroups => switch (_grouping) {
    _LibraryGrouping.books => false,
    _LibraryGrouping.authors =>
      _selectedAuthor == null || _selectedSeries == null,
    _LibraryGrouping.narrators => _selectedNarrator == null,
    _LibraryGrouping.series => _selectedSeries == null,
  };

  List<LibraryWorkSummary> get _displayedWorks {
    var works = _visibleWorks;
    final author = _selectedAuthor;
    final narrator = _selectedNarrator;
    final series = _selectedSeries;
    if (author != null) {
      works = works
          .where(
            (work) => (work.authors.isEmpty ? [work.author] : work.authors)
                .contains(author),
          )
          .toList();
    }
    if (narrator != null) {
      works = works.where((work) => work.narrators.contains(narrator)).toList();
    }
    if (series != null) {
      works = works.where((work) => (work.series ?? '') == series).toList();
      if (_query.sort == LibraryWorkSort.relevance) {
        works.sort((left, right) {
          final sequence = (left.seriesSequence ?? double.infinity).compareTo(
            right.seriesSequence ?? double.infinity,
          );
          return sequence != 0
              ? sequence
              : left.title.toLowerCase().compareTo(right.title.toLowerCase());
        });
      }
    }
    return works;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 760) return _mobile(context);
        if (constraints.maxWidth < 1200) return _medium(context);
        return _desktop(context);
      },
    );
  }

  Widget _desktop(BuildContext context) {
    final works = _displayedWorks;
    final selected = _showingGroups || works.isEmpty
        ? null
        : works[_selectedIndex.clamp(0, works.length - 1)];
    return Scaffold(
      bottomNavigationBar: widget.player == null || _playerExpanded
          ? null
          : _PlayerBar(
              controller: widget.player!,
              onExpand: () => setState(() => _playerExpanded = true),
            ),
      body: SafeArea(
        child: Column(
          children: [
            _TopBar(
              onToggleTheme: widget.onToggleTheme,
              libraryName: widget.libraryName,
              indexEvent: widget.indexEvent,
              onRescan: widget.onRescan,
              onClose: widget.onClose,
              onSearch: _setSearch,
              searchController: _searchController,
              onExportDiagnostics: widget.onExportDiagnostics,
              onOpenSettings: widget.peerServer == null
                  ? null
                  : () => _openServerSettings(context),
              detailPaneVisible: _detailPaneVisible,
              onToggleDetails: () => setState(() {
                _detailPaneVisible = !_detailPaneVisible;
                if (_detailPaneVisible) _inlineDetailWork = null;
              }),
            ),
            Expanded(
              child: Row(
                children: [
                  SizedBox(
                    width: _leftPaneWidth,
                    child: _Sidebar(
                      selectedSection: _section,
                      onSelectSection: (section) => setState(() {
                        _section = section;
                        _inlineDetailWork = null;
                        _playerExpanded = false;
                      }),
                      onOpenSettings: widget.peerServer == null
                          ? null
                          : () => _openServerSettings(context),
                    ),
                  ),
                  _ResizeHandle(
                    onDrag: (delta) => setState(
                      () => _leftPaneWidth = (_leftPaneWidth + delta).clamp(
                        180,
                        420,
                      ),
                    ),
                    onReset: () => setState(() => _leftPaneWidth = 236),
                  ),
                  Expanded(
                    child: _playerExpanded && widget.player != null
                        ? _ExpandedPlayer(
                            controller: widget.player!,
                            library: widget.library,
                            onCollapse: () =>
                                setState(() => _playerExpanded = false),
                            onPlay: widget.onPlay,
                            onSelectAuthor: _showAuthor,
                            onSelectNarrator: _showNarrator,
                          )
                        : _section == _LibrarySection.playlists
                        ? _playlists(context)
                        : !_detailPaneVisible && _inlineDetailWork != null
                        ? _inlineDetail(_inlineDetailWork!)
                        : _library(context),
                  ),
                  if (_detailPaneVisible &&
                      !_playerExpanded &&
                      _section == _LibrarySection.library) ...[
                    _ResizeHandle(
                      onDrag: (delta) => setState(
                        () => _detailPaneWidth = (_detailPaneWidth - delta)
                            .clamp(280, 680),
                      ),
                      onReset: () => setState(() => _detailPaneWidth = 368),
                    ),
                    SizedBox(
                      width: _detailPaneWidth,
                      child: _DetailPanel(
                        work: selected,
                        library: widget.library,
                        player: widget.player,
                        onPlay: widget.onPlay,
                        onDeleteMissingWork: _deleteMissingWork,
                        onMetadataChanged: _metadataChanged,
                        onSelectAuthor: _showAuthor,
                        onSelectNarrator: _showNarrator,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _medium(BuildContext context) {
    return Scaffold(
      bottomNavigationBar: widget.player == null || _playerExpanded
          ? null
          : _PlayerBar(
              controller: widget.player!,
              onExpand: () => setState(() => _playerExpanded = true),
            ),
      body: SafeArea(
        child: Column(
          children: [
            _TopBar(
              onToggleTheme: widget.onToggleTheme,
              libraryName: widget.libraryName,
              indexEvent: widget.indexEvent,
              onRescan: widget.onRescan,
              onClose: widget.onClose,
              onSearch: _setSearch,
              searchController: _searchController,
              onExportDiagnostics: widget.onExportDiagnostics,
              onOpenSettings: widget.peerServer == null
                  ? null
                  : () => _openServerSettings(context),
            ),
            Expanded(
              child: Row(
                children: [
                  NavigationRail(
                    selectedIndex: _section.index,
                    onDestinationSelected: (value) => setState(() {
                      _section = _LibrarySection.values[value];
                      _inlineDetailWork = null;
                      _playerExpanded = false;
                    }),
                    labelType: NavigationRailLabelType.all,
                    destinations: const [
                      NavigationRailDestination(
                        icon: Icon(Icons.headphones_outlined),
                        selectedIcon: Icon(Icons.headphones),
                        label: Text('Hörbücher'),
                      ),
                      NavigationRailDestination(
                        icon: Icon(Icons.queue_music_outlined),
                        selectedIcon: Icon(Icons.queue_music),
                        label: Text('Playlists'),
                      ),
                    ],
                  ),
                  const VerticalDivider(width: 1),
                  Expanded(
                    child: _playerExpanded && widget.player != null
                        ? _ExpandedPlayer(
                            controller: widget.player!,
                            library: widget.library,
                            onCollapse: () =>
                                setState(() => _playerExpanded = false),
                            onPlay: widget.onPlay,
                            onSelectAuthor: _showAuthor,
                            onSelectNarrator: _showNarrator,
                          )
                        : _section == _LibrarySection.playlists
                        ? _playlists(context)
                        : _inlineDetailWork == null
                        ? _library(context, detailAsDialog: true)
                        : _inlineDetail(_inlineDetailWork!),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _mobile(BuildContext context) {
    final pages = [
      _library(context, detailAsDialog: true),
      _library(context, detailAsDialog: true, showSearch: true),
      _playlists(context),
      widget.offlineWorks.isEmpty
          ? const Center(child: Text('Noch keine Offline-Downloads.'))
          : ListView(
              padding: const EdgeInsets.all(12),
              children: [
                for (final offline in widget.offlineWorks)
                  Card(
                    child: ListTile(
                      leading: offline.coverPath == null
                          ? const Icon(Icons.download_done)
                          : ClipRRect(
                              borderRadius: BorderRadius.circular(4),
                              child: Image.file(
                                File(offline.coverPath!),
                                width: 42,
                                height: 52,
                                fit: BoxFit.cover,
                              ),
                            ),
                      title: Text(offline.title),
                      subtitle: const Text('Offline verfügbar'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: widget.onOpenDownloads,
                    ),
                  ),
              ],
            ),
      Center(
        child: FilledButton.icon(
          onPressed: widget.peerServer == null
              ? null
              : () => _openServerSettings(context),
          icon: const Icon(Icons.lan_outlined),
          label: const Text('Server & Freigaben'),
        ),
      ),
    ];
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _playerExpanded
              ? widget.player?.work?.title ?? 'Player'
              : _mobileDestination == 2
              ? 'Playlists'
              : 'Hörbücher & Hörspiele',
        ),
        actions: [
          if (_playerExpanded)
            IconButton(
              onPressed: () => setState(() => _playerExpanded = false),
              tooltip: 'Player verkleinern',
              icon: const Icon(Icons.close_fullscreen),
            )
          else if (widget.onClose != null)
            IconButton(
              onPressed: widget.onClose,
              tooltip: 'Bibliothek oder Server wechseln',
              icon: const Icon(Icons.home_outlined),
            ),
          if (!_playerExpanded)
            IconButton(
              onPressed: widget.onToggleTheme,
              tooltip: 'Theme wechseln',
              icon: const Icon(Icons.contrast),
            ),
        ],
      ),
      body: _playerExpanded && widget.player != null
          ? _ExpandedPlayer(
              controller: widget.player!,
              library: widget.library,
              onCollapse: () => setState(() => _playerExpanded = false),
              onPlay: widget.onPlay,
              onSelectAuthor: _showAuthor,
              onSelectNarrator: _showNarrator,
            )
          : pages[_mobileDestination],
      bottomNavigationBar: _playerExpanded
          ? null
          : Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (widget.player != null && !_playerExpanded)
                  _PlayerBar(
                    controller: widget.player!,
                    compact: true,
                    onExpand: () => setState(() => _playerExpanded = true),
                  ),
                NavigationBar(
                  selectedIndex: _mobileDestination,
                  onDestinationSelected: (value) =>
                      setState(() => _mobileDestination = value),
                  destinations: const [
                    NavigationDestination(
                      icon: Icon(Icons.library_books_outlined),
                      label: 'Bibliothek',
                    ),
                    NavigationDestination(
                      icon: Icon(Icons.search),
                      label: 'Suche',
                    ),
                    NavigationDestination(
                      icon: Icon(Icons.queue_music_outlined),
                      label: 'Playlists',
                    ),
                    NavigationDestination(
                      icon: Icon(Icons.download_outlined),
                      label: 'Downloads',
                    ),
                    NavigationDestination(
                      icon: Icon(Icons.more_horiz),
                      label: 'Mehr',
                    ),
                  ],
                ),
              ],
            ),
    );
  }

  static const _playlistMediaTypes = {
    'audiobook': 'Hörbücher & Hörspiele',
    'video': 'Filme & Serien',
    'ebook': 'E-Books & PDFs',
    'image': 'Bilder',
    'podcast': 'Podcasts',
    'custom': 'Eigene Medien',
  };

  Widget _playlists(BuildContext context) {
    final library = widget.library;
    if (library == null) {
      return const Center(
        child: Text('Playlists sind für lokale Bibliotheken verfügbar.'),
      );
    }
    final playlists = library
        .listPlaylists()
        .where(
          (playlist) =>
              _playlistTypeFilter == null ||
              playlist.mediaType == _playlistTypeFilter,
        )
        .toList(growable: false);
    final worksById = {for (final work in widget.works) work.id: work};
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Playlists', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              Wrap(
                spacing: 12,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  SizedBox(
                    width: 210,
                    child: DropdownButtonFormField<String?>(
                      initialValue: _playlistTypeFilter,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'Medientyp',
                        prefixIcon: Icon(Icons.filter_list),
                      ),
                      items: [
                        const DropdownMenuItem<String?>(
                          value: null,
                          child: Text('Alle Typen'),
                        ),
                        for (final entry in _playlistMediaTypes.entries)
                          DropdownMenuItem<String?>(
                            value: entry.key,
                            child: Text(entry.value),
                          ),
                      ],
                      onChanged: (value) =>
                          setState(() => _playlistTypeFilter = value),
                    ),
                  ),
                  FilledButton.icon(
                    onPressed: library.isReadOnly ? null : _createPlaylist,
                    icon: const Icon(Icons.playlist_add),
                    label: const Text('Neue Playlist'),
                  ),
                ],
              ),
            ],
          ),
        ),
        Expanded(
          child: playlists.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.queue_music_outlined, size: 64),
                      const SizedBox(height: 12),
                      Text(
                        _playlistTypeFilter == null
                            ? 'Noch keine Playlists gespeichert.'
                            : 'Keine Playlist für diesen Medientyp.',
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: playlists.length,
                  itemBuilder: (context, index) {
                    final playlist = playlists[index];
                    final available = playlist.workIds
                        .map((id) => worksById[id])
                        .whereType<LibraryWorkSummary>()
                        .where((work) => work.available)
                        .toList(growable: false);
                    return Card(
                      child: ListTile(
                        onTap: () => _playLibraryPlaylist(playlist, available),
                        leading: const Icon(Icons.queue_music, size: 34),
                        title: Text(playlist.name),
                        subtitle: Text(
                          '${_playlistTypeLabel(playlist.mediaType)} · ${available.length} Werk(e) · Revision ${playlist.revision}',
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              onPressed: available.isEmpty
                                  ? null
                                  : () => _playLibraryPlaylist(
                                      playlist,
                                      available,
                                    ),
                              tooltip: 'Playlist abspielen',
                              icon: const Icon(Icons.play_arrow),
                            ),
                            IconButton(
                              onPressed: library.isReadOnly
                                  ? null
                                  : () => _editPlaylist(playlist),
                              tooltip: 'Inhalte verwalten',
                              icon: const Icon(Icons.edit_outlined),
                            ),
                            IconButton(
                              onPressed: library.isReadOnly
                                  ? null
                                  : () => _deleteLibraryPlaylist(playlist),
                              tooltip: 'Playlist löschen',
                              icon: const Icon(Icons.delete_outline),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  String _playlistTypeLabel(String? type) =>
      type == null ? 'Gemischte Medien' : _playlistMediaTypes[type] ?? type;

  Future<void> _playLibraryPlaylist(
    LibraryPlaylist playlist,
    List<LibraryWorkSummary> available,
  ) async {
    if (available.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Diese Playlist ist noch leer. Über den Stift kannst du Werke hinzufügen.',
          ),
        ),
      );
      return;
    }
    final play = widget.onPlayPlaylist;
    if (play == null) return;
    try {
      await play(playlist.id);
      if (mounted) setState(() => _playerExpanded = true);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Playlist konnte nicht gestartet werden: $error'),
        ),
      );
    }
  }

  Future<void> _createPlaylist() async {
    final library = widget.library;
    if (library == null) return;
    final nameController = TextEditingController();
    var mediaType = 'audiobook';
    final result = await showDialog<({String name, String type})>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Neue Playlist'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameController,
                  autofocus: true,
                  decoration: const InputDecoration(labelText: 'Name'),
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<String>(
                  initialValue: mediaType,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Medientyp'),
                  items: [
                    for (final entry in _playlistMediaTypes.entries)
                      DropdownMenuItem(
                        value: entry.key,
                        child: Text(entry.value),
                      ),
                  ],
                  onChanged: (value) {
                    if (value != null) {
                      setDialogState(() => mediaType = value);
                    }
                  },
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Abbrechen'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, (
                name: nameController.text,
                type: mediaType,
              )),
              child: const Text('Erstellen'),
            ),
          ],
        ),
      ),
    );
    nameController.dispose();
    if (result == null || result.name.trim().isEmpty || !mounted) return;
    library.savePlaylist(
      name: result.name,
      workIds: const [],
      mediaType: result.type,
    );
    widget.player?.refreshSavedPlaylists();
    setState(() {});
  }

  Future<void> _editPlaylist(LibraryPlaylist playlist) async {
    final library = widget.library;
    if (library == null) return;
    final candidates = widget.works
        .where(
          (work) =>
              playlist.mediaType == null || work.kind == playlist.mediaType,
        )
        .toList(growable: false);
    final selected = playlist.workIds.toSet();
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text('„${playlist.name}“ verwalten'),
          content: SizedBox(
            width: 520,
            height: 520,
            child: candidates.isEmpty
                ? const Center(
                    child: Text('Keine passenden Medien in der Bibliothek.'),
                  )
                : ListView(
                    children: [
                      for (final work in candidates)
                        CheckboxListTile(
                          value: selected.contains(work.id),
                          title: Text(work.title),
                          subtitle: Text(work.author),
                          onChanged: (checked) => setDialogState(() {
                            checked == true
                                ? selected.add(work.id)
                                : selected.remove(work.id);
                          }),
                        ),
                    ],
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Abbrechen'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Speichern'),
            ),
          ],
        ),
      ),
    );
    if (saved != true || !mounted) return;
    library.savePlaylist(
      playlistId: playlist.id,
      name: playlist.name,
      mediaType: playlist.mediaType,
      workIds: [
        for (final work in candidates)
          if (selected.contains(work.id)) work.id,
      ],
    );
    widget.player?.refreshSavedPlaylists();
    setState(() {});
  }

  Future<void> _deleteLibraryPlaylist(LibraryPlaylist playlist) async {
    final library = widget.library;
    if (library == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Playlist löschen?'),
        content: Text('„${playlist.name}“ wird dauerhaft gelöscht.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Löschen'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    library.deletePlaylist(playlist.id);
    widget.player?.refreshSavedPlaylists();
    setState(() {});
  }

  Widget _library(
    BuildContext context, {
    bool detailAsDialog = false,
    bool showSearch = false,
  }) {
    final works = _displayedWorks;
    return Column(
      children: [
        if (showSearch)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: SearchBar(
              leading: const Icon(Icons.search),
              hintText: 'Titel, Person oder Serie …',
              onChanged: _setSearch,
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final title = _libraryTitle(context);
              final controls = _libraryControls();
              if (constraints.maxWidth >= 720) {
                return Row(
                  children: [
                    Expanded(child: title),
                    controls,
                  ],
                );
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  title,
                  const SizedBox(height: 6),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: controls,
                  ),
                ],
              );
            },
          ),
        ),
        Expanded(
          child: _showingGroups
              ? _groupBrowser(detailAsDialog: detailAsDialog)
              : works.isEmpty
              ? _EmptyLibrary(
                  searchActive:
                      _query.text.isNotEmpty || _query.kinds.isNotEmpty,
                )
              : _layout == _LibraryLayout.grid
              ? GridView.builder(
                  padding: const EdgeInsets.all(16),
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 220,
                    childAspectRatio: .72,
                    mainAxisSpacing: 14,
                    crossAxisSpacing: 14,
                  ),
                  itemCount: works.length,
                  itemBuilder: (context, index) {
                    final work = works[index];
                    return _WorkCard(
                      work: work,
                      player: widget.player,
                      selected: !detailAsDialog && index == _selectedIndex,
                      onTap: () {
                        setState(() => _selectedIndex = index);
                        if (detailAsDialog || !_detailPaneVisible) {
                          _openWorkDetails(work);
                        }
                      },
                    );
                  },
                )
              : _workTable(works, detailAsDialog: detailAsDialog),
        ),
      ],
    );
  }

  Future<void> _openServerSettings(BuildContext context) async {
    final controller = widget.peerServer;
    if (controller == null) return;
    await showFundusServerSettings(
      context,
      controller,
      offlineStore: widget.offlineStore,
      themeMode: widget.themeMode,
      onThemeModeChanged: widget.onThemeModeChanged,
      onExportDiagnostics: widget.onExportDiagnostics,
    );
  }

  Widget _libraryTitle(BuildContext context) => Row(
    children: [
      if (_selectedAuthor != null ||
          _selectedNarrator != null ||
          _selectedSeries != null)
        IconButton(
          onPressed: _navigateUp,
          tooltip: 'Eine Ebene zurück',
          icon: const Icon(Icons.arrow_back),
        ),
      Expanded(
        child: Text(
          _browserTitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.titleMedium,
        ),
      ),
    ],
  );

  Widget _libraryControls() => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      _AdvancedFilterButton(
        query: _query,
        works: widget.works,
        onChanged: (query) => setState(() {
          _query = query;
          _selectedIndex = 0;
        }),
      ),
      const SizedBox(width: 4),
      MenuAnchor(
        builder: (context, controller, child) => IconButton(
          onPressed: controller.isOpen ? controller.close : controller.open,
          tooltip: 'Gespeicherte Ansichten',
          icon: const Icon(Icons.bookmarks_outlined),
        ),
        menuChildren: [
          MenuItemButton(
            onPressed: widget.library?.isReadOnly == false
                ? _saveCurrentView
                : null,
            leadingIcon: const Icon(Icons.bookmark_add_outlined),
            child: const Text('Aktuelle Ansicht speichern'),
          ),
          if (_savedViews.isNotEmpty) const Divider(),
          for (final view in _savedViews)
            MenuItemButton(
              onPressed: () => _applySavedView(view),
              leadingIcon: const Icon(Icons.bookmark_outline),
              child: Text(view.name),
            ),
          if (_savedViews.isNotEmpty)
            MenuItemButton(
              onPressed: _manageSavedViews,
              leadingIcon: const Icon(Icons.edit_outlined),
              child: const Text('Ansichten verwalten'),
            ),
        ],
      ),
      PopupMenuButton<_LibraryGrouping>(
        tooltip: 'Gliederung wählen',
        initialValue: _grouping,
        onSelected: _setGrouping,
        itemBuilder: (context) => const [
          PopupMenuItem(
            value: _LibraryGrouping.books,
            child: Text('Nach Büchern'),
          ),
          PopupMenuItem(
            value: _LibraryGrouping.authors,
            child: Text('Nach Autoren'),
          ),
          PopupMenuItem(
            value: _LibraryGrouping.series,
            child: Text('Nach Serien'),
          ),
          PopupMenuItem(
            value: _LibraryGrouping.narrators,
            child: Text('Nach Sprechern'),
          ),
        ],
        child: Chip(
          avatar: const Icon(Icons.account_tree_outlined, size: 18),
          label: Text(_groupingLabel),
        ),
      ),
      const SizedBox(width: 8),
      SegmentedButton<_LibraryLayout>(
        showSelectedIcon: false,
        segments: const [
          ButtonSegment(
            value: _LibraryLayout.grid,
            icon: Icon(Icons.grid_view),
            tooltip: 'Kacheln',
          ),
          ButtonSegment(
            value: _LibraryLayout.table,
            icon: Icon(Icons.table_rows_outlined),
            tooltip: 'Tabelle',
          ),
        ],
        selected: {_layout},
        onSelectionChanged: (value) => setState(() => _layout = value.single),
      ),
      const SizedBox(width: 8),
      MenuAnchor(
        builder: (context, controller, child) => OutlinedButton.icon(
          onPressed: controller.isOpen ? controller.close : controller.open,
          icon: const Icon(Icons.sort, size: 18),
          label: Text(_sortLabel(_query.sort)),
        ),
        menuChildren: [
          for (final sort in LibraryWorkSort.values)
            MenuItemButton(
              onPressed: () => _setSort(sort),
              leadingIcon: _query.sort == sort
                  ? const Icon(Icons.check)
                  : const SizedBox(width: 24),
              child: Text(_sortLabel(sort)),
            ),
        ],
      ),
    ],
  );

  String get _browserTitle {
    if (_selectedSeries != null) {
      return _selectedSeries!.isEmpty ? 'Einzelbände' : _selectedSeries!;
    }
    if (_selectedAuthor != null) return _selectedAuthor!;
    if (_selectedNarrator != null) return 'Gesprochen von $_selectedNarrator';
    return 'Hörbücher & Hörspiele';
  }

  String get _groupingLabel => switch (_grouping) {
    _LibraryGrouping.books => 'Bücher',
    _LibraryGrouping.authors => 'Autoren',
    _LibraryGrouping.series => 'Serien',
    _LibraryGrouping.narrators => 'Sprecher',
  };

  List<_LibraryGroup> get _groups {
    final works = _visibleWorks;
    final grouped = <String, List<LibraryWorkSummary>>{};
    if (_grouping == _LibraryGrouping.authors && _selectedAuthor == null) {
      for (final work in works) {
        final authors = work.authors.isEmpty ? [work.author] : work.authors;
        for (final author in authors) {
          grouped.putIfAbsent(author, () => []).add(work);
        }
      }
      return grouped.entries
          .map(
            (entry) => _LibraryGroup(
              title: entry.key,
              subtitle: '${entry.value.length} Hörbuch/Hörbücher',
              author: entry.key,
              series: null,
              narrator: null,
              icon: Icons.person_outline,
            ),
          )
          .toList()
        ..sort(
          (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
        );
    }

    if (_grouping == _LibraryGrouping.narrators && _selectedNarrator == null) {
      for (final work in works) {
        for (final narrator in work.narrators) {
          grouped.putIfAbsent(narrator, () => []).add(work);
        }
      }
      return grouped.entries
          .map(
            (entry) => _LibraryGroup(
              title: entry.key,
              subtitle: '${entry.value.length} Hörbuch/Hörbücher',
              author: '',
              series: null,
              narrator: entry.key,
              icon: Icons.mic_none,
            ),
          )
          .toList()
        ..sort(
          (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
        );
    }

    final authorWorks = _selectedAuthor == null
        ? works
        : works
              .where(
                (work) => (work.authors.isEmpty ? [work.author] : work.authors)
                    .contains(_selectedAuthor),
              )
              .toList();
    for (final work in authorWorks) {
      final series = work.series ?? '';
      final key = '${work.author}\u0000$series';
      grouped.putIfAbsent(key, () => []).add(work);
    }
    return grouped.entries.map((entry) {
      final values = entry.value;
      final first = values.first;
      final series = first.series ?? '';
      return _LibraryGroup(
        title: series.isEmpty ? 'Einzelbände' : series,
        subtitle: _selectedAuthor == null
            ? '${first.author} · ${values.length} Hörbuch/Hörbücher'
            : '${values.length} Hörbuch/Hörbücher',
        author: first.author,
        series: series,
        narrator: null,
        icon: series.isEmpty ? Icons.menu_book_outlined : Icons.library_books,
      );
    }).toList()..sort((a, b) {
      final author = a.author.toLowerCase().compareTo(b.author.toLowerCase());
      if (author != 0 && _selectedAuthor == null) return author;
      return a.title.toLowerCase().compareTo(b.title.toLowerCase());
    });
  }

  Widget _groupBrowser({required bool detailAsDialog}) {
    final groups = _groups;
    if (groups.isEmpty) {
      return _EmptyLibrary(
        searchActive: _query.text.isNotEmpty || _query.kinds.isNotEmpty,
      );
    }
    if (_layout == _LibraryLayout.table) {
      return ListView.separated(
        padding: const EdgeInsets.all(16),
        itemCount: groups.length,
        separatorBuilder: (context, index) => const Divider(height: 1),
        itemBuilder: (context, index) {
          final group = groups[index];
          return ListTile(
            leading: Icon(group.icon),
            title: Text(group.title),
            subtitle: Text(group.subtitle),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _openGroup(group),
          );
        },
      );
    }
    return GridView.builder(
      padding: const EdgeInsets.all(16),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 280,
        childAspectRatio: 1.8,
        mainAxisSpacing: 14,
        crossAxisSpacing: 14,
      ),
      itemCount: groups.length,
      itemBuilder: (context, index) {
        final group = groups[index];
        return Card(
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => _openGroup(group),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  Icon(group.icon, size: 42),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          group.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        Text(
                          group.subtitle,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  const Icon(Icons.chevron_right),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _workTable(
    List<LibraryWorkSummary> works, {
    required bool detailAsDialog,
  }) {
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.all(16),
        child: SizedBox(
          width: constraints.maxWidth > 1082 ? constraints.maxWidth - 32 : 1050,
          child: SingleChildScrollView(
            child: DataTable(
              showCheckboxColumn: false,
              columns: const [
                DataColumn(label: Text('Cover')),
                DataColumn(label: Text('Titel')),
                DataColumn(label: Text('Status')),
                DataColumn(label: Text('Autor')),
                DataColumn(label: Text('Serie')),
                DataColumn(label: Text('Band')),
                DataColumn(label: Text('Sprache')),
                DataColumn(label: Text('Fortschritt')),
              ],
              rows: [
                for (var index = 0; index < works.length; index++)
                  DataRow(
                    selected: !detailAsDialog && index == _selectedIndex,
                    onSelectChanged: (_) =>
                        _selectWork(works[index], index, detailAsDialog),
                    cells: [
                      DataCell(
                        SizedBox.square(
                          dimension: 40,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(4),
                            child: _WorkCover(work: works[index], iconSize: 20),
                          ),
                        ),
                      ),
                      DataCell(Text(works[index].title)),
                      DataCell(
                        works[index].available
                            ? const Text('Verfügbar')
                            : const Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.warning_amber_rounded, size: 18),
                                  SizedBox(width: 5),
                                  Text('Fehlend'),
                                ],
                              ),
                      ),
                      DataCell(Text(works[index].author)),
                      DataCell(Text(works[index].series ?? '—')),
                      DataCell(
                        Text(
                          works[index].seriesSequence == null
                              ? '—'
                              : _formatSequence(works[index].seriesSequence!),
                        ),
                      ),
                      DataCell(Text(_displayLanguage(works[index].language))),
                      DataCell(
                        _ProgressLabel(
                          work: works[index],
                          player: widget.player,
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _selectWork(LibraryWorkSummary work, int index, bool detailAsDialog) {
    setState(() => _selectedIndex = index);
    if (!detailAsDialog && _detailPaneVisible) return;
    _openWorkDetails(work);
  }

  void _openWorkDetails(LibraryWorkSummary work) {
    if (MediaQuery.sizeOf(context).width >= 760) {
      setState(() => _inlineDetailWork = work);
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (context) => Scaffold(
          appBar: AppBar(title: Text(work.title)),
          body: SafeArea(
            child: _DetailPanel(
              work: work,
              library: widget.library,
              player: widget.player,
              onPlay: widget.onPlay,
              onDeleteMissingWork: _deleteMissingWork,
              onMetadataChanged: _metadataChanged,
              onSelectAuthor: _showAuthor,
              onSelectNarrator: _showNarrator,
            ),
          ),
        ),
      ),
    );
  }

  Widget _inlineDetail(LibraryWorkSummary work) => Column(
    children: [
      Align(
        alignment: Alignment.centerLeft,
        child: IconButton(
          onPressed: () => setState(() => _inlineDetailWork = null),
          tooltip: 'Zurück zur Übersicht',
          icon: const Icon(Icons.arrow_back),
        ),
      ),
      Expanded(
        child: _DetailPanel(
          work: work,
          library: widget.library,
          player: widget.player,
          onPlay: widget.onPlay,
          onDeleteMissingWork: _deleteMissingWork,
          onMetadataChanged: _metadataChanged,
          onSelectAuthor: _showAuthor,
          onSelectNarrator: _showNarrator,
        ),
      ),
    ],
  );

  Future<void> _deleteMissingWork(LibraryWorkSummary work) async {
    final callback = widget.onDeleteMissingWork;
    if (callback == null) return;
    await callback(work);
    if (!mounted) return;
    setState(() {
      if (_inlineDetailWork?.id == work.id) _inlineDetailWork = null;
      _selectedIndex = 0;
    });
  }

  void _metadataChanged(LibraryWorkSummary work) {
    widget.onMetadataChanged?.call(work);
    if (!mounted) return;
    setState(() {
      if (_inlineDetailWork?.id == work.id) _inlineDetailWork = work;
    });
  }

  void _openGroup(_LibraryGroup group) => setState(() {
    _selectedIndex = 0;
    if (_grouping == _LibraryGrouping.narrators) {
      _selectedNarrator = group.narrator;
    } else if (_grouping == _LibraryGrouping.authors &&
        _selectedAuthor == null) {
      _selectedAuthor = group.author;
    } else {
      _selectedAuthor = group.author;
      _selectedSeries = group.series;
    }
  });

  void _navigateUp() => setState(() {
    _selectedIndex = 0;
    if (_grouping == _LibraryGrouping.authors && _selectedSeries != null) {
      _selectedSeries = null;
    } else {
      _selectedAuthor = null;
      _selectedNarrator = null;
      _selectedSeries = null;
    }
  });

  void _setGrouping(_LibraryGrouping value) => setState(() {
    _grouping = value;
    _selectedAuthor = null;
    _selectedNarrator = null;
    _selectedSeries = null;
    _selectedIndex = 0;
  });

  void _showAuthor(String author) => setState(() {
    _playerExpanded = false;
    _grouping = _LibraryGrouping.books;
    _selectedAuthor = author;
    _selectedNarrator = null;
    _selectedSeries = null;
    _inlineDetailWork = null;
    _selectedIndex = 0;
  });

  void _showNarrator(String narrator) => setState(() {
    _playerExpanded = false;
    _grouping = _LibraryGrouping.books;
    _selectedAuthor = null;
    _selectedNarrator = narrator;
    _selectedSeries = null;
    _inlineDetailWork = null;
    _selectedIndex = 0;
  });

  void _setSearch(String value) => setState(() {
    _selectedIndex = 0;
    _query = _query.copyWith(text: value);
  });

  Future<void> _loadSavedViews() async {
    final library = widget.library;
    final views = library == null
        ? const <LibrarySavedView>[]
        : await library.loadSavedViews();
    if (mounted && library == widget.library) {
      setState(() => _savedViews = views);
    }
  }

  Future<void> _saveCurrentView() async {
    final library = widget.library;
    if (library == null || library.isReadOnly) return;
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Ansicht speichern'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Name',
            hintText: 'Zum Beispiel: Angefangene deutsche Hörbücher',
          ),
          onSubmitted: (value) => Navigator.pop(context, value.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Speichern'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.isEmpty || !mounted) return;
    final views = await library.saveView(name, _query);
    if (mounted) setState(() => _savedViews = views);
  }

  void _applySavedView(LibrarySavedView view) => setState(() {
    _query = view.query;
    _searchController.text = view.query.text;
    _selectedIndex = 0;
    _selectedAuthor = null;
    _selectedNarrator = null;
    _selectedSeries = null;
  });

  Future<void> _manageSavedViews() async {
    final library = widget.library;
    if (library == null || library.isReadOnly) return;
    await showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Gespeicherte Ansichten'),
          content: SizedBox(
            width: 460,
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final view in _savedViews)
                  ListTile(
                    title: Text(view.name),
                    subtitle: Text(
                      '${view.query.hasFilters ? 'Mit Filtern' : 'Ohne Filter'} · ${_sortLabel(view.query.sort)}',
                    ),
                    trailing: IconButton(
                      tooltip: 'Ansicht löschen',
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () async {
                        final views = await library.deleteSavedView(view.id);
                        if (!mounted) return;
                        setState(() => _savedViews = views);
                        setDialogState(() {});
                      },
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Fertig'),
            ),
          ],
        ),
      ),
    );
  }

  void _setSort(LibraryWorkSort value) => setState(() {
    _selectedIndex = 0;
    _query = _query.copyWith(sort: value);
  });

  static String _sortLabel(LibraryWorkSort sort) => switch (sort) {
    LibraryWorkSort.relevance => 'Relevanz',
    LibraryWorkSort.recentlyAdded => 'Zuletzt hinzugefügt',
    LibraryWorkSort.recentlyListened => 'Zuletzt gehört',
    LibraryWorkSort.title => 'Titel A–Z',
    LibraryWorkSort.author => 'Autor A–Z',
    LibraryWorkSort.series => 'Serie & Reihenfolge',
    LibraryWorkSort.progress => 'Fortschritt',
    LibraryWorkSort.duration => 'Dauer',
  };
}

enum _LibrarySection { library, playlists }

enum _LibraryLayout { grid, table }

enum _LibraryGrouping { books, authors, series, narrators }

final class _LibraryGroup {
  const _LibraryGroup({
    required this.title,
    required this.subtitle,
    required this.author,
    required this.series,
    required this.narrator,
    required this.icon,
  });

  final String title;
  final String subtitle;
  final String author;
  final String? series;
  final String? narrator;
  final IconData icon;
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.onToggleTheme,
    this.libraryName,
    this.indexEvent,
    this.onRescan,
    this.onClose,
    required this.onSearch,
    required this.searchController,
    this.onExportDiagnostics,
    this.detailPaneVisible,
    this.onToggleDetails,
    this.onOpenSettings,
  });

  final VoidCallback onToggleTheme;
  final String? libraryName;
  final LibraryIndexEvent? indexEvent;
  final VoidCallback? onRescan;
  final VoidCallback? onClose;
  final ValueChanged<String> onSearch;
  final SearchController searchController;
  final VoidCallback? onExportDiagnostics;
  final bool? detailPaneVisible;
  final VoidCallback? onToggleDetails;
  final VoidCallback? onOpenSettings;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 52,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            Text('Fundus', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(width: 14),
            Text(
              '${libraryName ?? 'Entwicklung'} · Hörbücher',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const Spacer(),
            SizedBox(
              width: 320,
              child: SearchBar(
                controller: searchController,
                leading: const Icon(Icons.search),
                hintText: 'Suchen und filtern …',
                onChanged: onSearch,
              ),
            ),
            if (indexEvent != null)
              Padding(
                padding: const EdgeInsets.only(left: 8),
                child: Text('${indexEvent!.fileCount} Dateien'),
              ),
            IconButton(
              onPressed: onRescan,
              tooltip: 'Neu einlesen',
              icon: const Icon(Icons.refresh),
            ),
            IconButton(
              onPressed: onToggleTheme,
              tooltip: 'Theme wechseln',
              icon: const Icon(Icons.contrast),
            ),
            if (onExportDiagnostics != null)
              IconButton(
                onPressed: onExportDiagnostics,
                tooltip: 'Diagnoseprotokoll exportieren',
                icon: const Icon(Icons.bug_report_outlined),
              ),
            if (onOpenSettings != null)
              IconButton(
                onPressed: onOpenSettings,
                tooltip: 'Server & Freigaben',
                icon: const Icon(Icons.lan_outlined),
              ),
            if (onToggleDetails != null)
              IconButton(
                onPressed: onToggleDetails,
                tooltip: detailPaneVisible ?? true
                    ? 'Detailleiste ausblenden'
                    : 'Detailleiste einblenden',
                icon: Icon(
                  detailPaneVisible ?? true
                      ? Icons.view_sidebar_outlined
                      : Icons.view_sidebar,
                ),
              ),
            if (onClose != null)
              IconButton(
                onPressed: onClose,
                tooltip: 'Bibliothek schließen',
                icon: const Icon(Icons.close),
              ),
          ],
        ),
      ),
    );
  }
}

class _AdvancedFilterButton extends StatelessWidget {
  const _AdvancedFilterButton({
    required this.query,
    required this.works,
    required this.onChanged,
  });

  final LibraryWorkQuery query;
  final List<LibraryWorkSummary> works;
  final ValueChanged<LibraryWorkQuery> onChanged;

  int get _filterCount =>
      query.kinds.length +
      query.languages.length +
      query.authors.length +
      query.narrators.length +
      query.series.length +
      query.tags.length +
      (query.progress == LibraryProgressFilter.any ? 0 : 1) +
      (query.offlineOnly ? 1 : 0);

  @override
  Widget build(BuildContext context) => IconButton.filledTonal(
    onPressed: () => _show(context),
    tooltip: 'Filter kombinieren',
    icon: Badge(
      isLabelVisible: _filterCount > 0,
      label: Text('$_filterCount'),
      child: const Icon(Icons.filter_list),
    ),
  );

  Future<void> _show(BuildContext context) async {
    var kinds = {...query.kinds};
    var languages = {...query.languages};
    var authors = {...query.authors};
    var narrators = {...query.narrators};
    var series = {...query.series};
    var tags = {...query.tags};
    var progress = query.progress;
    var offlineOnly = query.offlineOnly;
    final result = await showDialog<LibraryWorkQuery>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) {
          Set<String> values(Iterable<String?> source) => source
              .whereType<String>()
              .map((value) => value.trim())
              .where((value) => value.isNotEmpty)
              .toSet();
          final availableAuthors = values(
            works.expand(
              (work) => work.authors.isEmpty ? [work.author] : work.authors,
            ),
          );
          final availableNarrators = values(
            works.expand((work) => work.narrators),
          );
          final availableLanguages = values(works.map((work) => work.language));
          final availableSeries = values(works.map((work) => work.series));
          final availableTags = values(works.expand((work) => work.tags));
          Widget choices(
            String title,
            Set<String> available,
            Set<String> selected,
          ) {
            final sorted = available.toList()
              ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
            if (sorted.isEmpty) return const SizedBox.shrink();
            return Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      for (final value in sorted)
                        FilterChip(
                          label: Text(value),
                          selected: selected.contains(value),
                          onSelected: (_) => setState(() {
                            selected.contains(value)
                                ? selected.remove(value)
                                : selected.add(value);
                          }),
                        ),
                    ],
                  ),
                ],
              ),
            );
          }

          return AlertDialog(
            title: const Text('Medien filtern'),
            content: SizedBox(
              width: 680,
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    DropdownButtonFormField<LibraryProgressFilter>(
                      initialValue: progress,
                      decoration: const InputDecoration(
                        labelText: 'Hörstatus',
                        border: OutlineInputBorder(),
                      ),
                      items: const [
                        DropdownMenuItem(
                          value: LibraryProgressFilter.any,
                          child: Text('Alle'),
                        ),
                        DropdownMenuItem(
                          value: LibraryProgressFilter.notStarted,
                          child: Text('Nicht begonnen'),
                        ),
                        DropdownMenuItem(
                          value: LibraryProgressFilter.inProgress,
                          child: Text('Begonnen'),
                        ),
                        DropdownMenuItem(
                          value: LibraryProgressFilter.finished,
                          child: Text('Beendet'),
                        ),
                      ],
                      onChanged: (value) => setState(() => progress = value!),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Nur offline verfügbare Medien'),
                      value: offlineOnly,
                      onChanged: (value) => setState(() => offlineOnly = value),
                    ),
                    choices(
                      'Medientyp',
                      _MediaFilterButton.kinds.keys.toSet(),
                      kinds,
                    ),
                    choices('Sprache', availableLanguages, languages),
                    choices('Autor', availableAuthors, authors),
                    choices('Sprecher', availableNarrators, narrators),
                    choices('Serie', availableSeries, series),
                    choices(
                      'Tags (alle gewählten müssen passen)',
                      availableTags,
                      tags,
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(
                  context,
                  query.copyWith(
                    kinds: {},
                    progress: LibraryProgressFilter.any,
                    offlineOnly: false,
                    languages: {},
                    authors: {},
                    narrators: {},
                    series: {},
                    tags: {},
                  ),
                ),
                child: const Text('Zurücksetzen'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Abbrechen'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(
                  context,
                  query.copyWith(
                    kinds: kinds,
                    progress: progress,
                    offlineOnly: offlineOnly,
                    languages: languages,
                    authors: authors,
                    narrators: narrators,
                    series: series,
                    tags: tags,
                  ),
                ),
                child: const Text('Anwenden'),
              ),
            ],
          );
        },
      ),
    );
    if (result != null) onChanged(result);
  }
}

class _MediaFilterButton extends StatelessWidget {
  const _MediaFilterButton({
    required this.selectedKinds,
    required this.onChanged,
  });

  final Set<String> selectedKinds;
  final ValueChanged<Set<String>> onChanged;

  static const kinds = {
    'audiobook': 'Hörbücher',
    'video': 'Videos',
    'ebook': 'E-Books',
    'image': 'Bilder',
  };

  @override
  Widget build(BuildContext context) {
    return MenuAnchor(
      builder: (context, controller, child) => IconButton.filledTonal(
        onPressed: controller.isOpen ? controller.close : controller.open,
        tooltip: 'Medientyp filtern',
        icon: Badge(
          isLabelVisible: selectedKinds.isNotEmpty,
          label: Text('${selectedKinds.length}'),
          child: const Icon(Icons.filter_list),
        ),
      ),
      menuChildren: [
        MenuItemButton(
          onPressed: () => onChanged({}),
          leadingIcon: selectedKinds.isEmpty
              ? const Icon(Icons.check)
              : const SizedBox(width: 24),
          child: const Text('Alle Medientypen'),
        ),
        for (final entry in kinds.entries)
          MenuItemButton(
            onPressed: () {
              final next = {...selectedKinds};
              next.contains(entry.key)
                  ? next.remove(entry.key)
                  : next.add(entry.key);
              onChanged(next);
            },
            leadingIcon: selectedKinds.contains(entry.key)
                ? const Icon(Icons.check)
                : const SizedBox(width: 24),
            child: Text(entry.value),
          ),
      ],
    );
  }
}

class _Sidebar extends StatelessWidget {
  const _Sidebar({
    required this.selectedSection,
    required this.onSelectSection,
    this.onOpenSettings,
  });

  final _LibrarySection selectedSection;
  final ValueChanged<_LibrarySection> onSelectSection;
  final VoidCallback? onOpenSettings;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(10),
      children: [
        const _SectionLabel('Bibliothek'),
        ListTile(
          leading: const Icon(Icons.headphones),
          title: const Text('Hörbücher'),
          selected: selectedSection == _LibrarySection.library,
          onTap: () => onSelectSection(_LibrarySection.library),
        ),
        const ListTile(
          leading: Icon(Icons.movie_outlined),
          title: Text('Filme & Serien'),
        ),
        const ListTile(
          leading: Icon(Icons.menu_book_outlined),
          title: Text('E-Books & PDFs'),
        ),
        const SizedBox(height: 12),
        const _SectionLabel('Entdecken'),
        const ListTile(
          leading: Icon(Icons.account_tree_outlined),
          title: Text('Serien'),
        ),
        const ListTile(
          leading: Icon(Icons.people_outline),
          title: Text('Personen'),
        ),
        const ListTile(leading: Icon(Icons.tag), title: Text('Tags')),
        const ListTile(
          leading: Icon(Icons.star_outline),
          title: Text('Sammlungen'),
        ),
        ListTile(
          leading: const Icon(Icons.queue_music_outlined),
          title: const Text('Playlists'),
          selected: selectedSection == _LibrarySection.playlists,
          onTap: () => onSelectSection(_LibrarySection.playlists),
        ),
        const ListTile(
          leading: Icon(Icons.folder_outlined),
          title: Text('Ordner'),
        ),
        const SizedBox(height: 12),
        const _SectionLabel('System'),
        ListTile(
          leading: const Icon(Icons.lan_outlined),
          title: const Text('Server & Freigaben'),
          onTap: onOpenSettings,
        ),
      ],
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
    child: Text(
      text.toUpperCase(),
      style: Theme.of(context).textTheme.labelSmall,
    ),
  );
}

class _ResizeHandle extends StatelessWidget {
  const _ResizeHandle({required this.onDrag, required this.onReset});

  final ValueChanged<double> onDrag;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) => MouseRegion(
    cursor: SystemMouseCursors.resizeColumn,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onHorizontalDragUpdate: (details) => onDrag(details.delta.dx),
      onDoubleTap: onReset,
      child: const SizedBox(
        width: 7,
        child: Center(child: VerticalDivider(width: 1)),
      ),
    ),
  );
}

class _WorkCard extends StatelessWidget {
  const _WorkCard({
    required this.work,
    required this.selected,
    required this.onTap,
    this.player,
  });

  final LibraryWorkSummary work;
  final bool selected;
  final VoidCallback onTap;
  final FundusPlayerController? player;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      selected: selected,
      label:
          '${work.title}, ${work.author}${work.available ? '' : ', Dateien fehlen'}',
      child: Card(
        color: selected
            ? scheme.secondaryContainer.withValues(alpha: .35)
            : null,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          scheme.primaryContainer,
                          scheme.surfaceContainerHighest,
                        ],
                      ),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        _WorkCover(work: work, iconSize: 42, player: player),
                        if (work.seriesSequence case final sequence?)
                          Positioned(
                            left: 8,
                            top: 8,
                            child: Badge(
                              largeSize: 28,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                              ),
                              label: Text('Band ${_formatSequence(sequence)}'),
                            ),
                          ),
                        if (!work.available)
                          Positioned(
                            right: 8,
                            top: 8,
                            child: Badge(
                              backgroundColor: scheme.errorContainer,
                              textColor: scheme.onErrorContainer,
                              largeSize: 28,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                              ),
                              label: const Text('Fehlend'),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Text(work.title, maxLines: 2, overflow: TextOverflow.ellipsis),
                Text(
                  work.series == null
                      ? work.author
                      : '${work.author} · ${work.series}'
                            '${work.seriesSequence == null ? '' : ' · Band ${_formatSequence(work.seriesSequence!)}'}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AudiobookHero extends StatelessWidget {
  const _AudiobookHero({
    required this.work,
    required this.directoryPath,
    required this.player,
    required this.playing,
    required this.playbackEnabled,
    required this.onTogglePlayback,
    this.onSelectAuthor,
    this.onSelectNarrator,
  });

  final LibraryWorkSummary work;
  final String? directoryPath;
  final FundusPlayerController? player;
  final bool playing;
  final bool playbackEnabled;
  final VoidCallback onTogglePlayback;
  final ValueChanged<String>? onSelectAuthor;
  final ValueChanged<String>? onSelectNarrator;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final wide = constraints.maxWidth >= 720;
      final scheme = Theme.of(context).colorScheme;
      final content = wide
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: (constraints.maxWidth * .27).clamp(240, 340),
                  child: _cover(),
                ),
                const SizedBox(width: 32),
                Expanded(child: _facts(context, wide: true)),
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(child: SizedBox(width: 230, child: _cover())),
                const SizedBox(height: 20),
                _facts(context, wide: false),
              ],
            );
      return DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              scheme.primaryContainer.withValues(alpha: .34),
              scheme.surfaceContainer.withValues(alpha: .55),
            ],
          ),
          border: Border.all(color: scheme.outlineVariant),
        ),
        child: Padding(padding: EdgeInsets.all(wide ? 28 : 18), child: content),
      );
    },
  );

  Widget _cover() => AspectRatio(
    aspectRatio: .72,
    child: ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: _WorkCover(work: work, iconSize: 88, player: player),
    ),
  );

  Widget _facts(BuildContext context, {required bool wide}) {
    final authors = work.authors.isEmpty ? [work.author] : work.authors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          work.title,
          style: wide
              ? Theme.of(context).textTheme.displaySmall
              : Theme.of(context).textTheme.headlineMedium,
        ),
        if (work.subtitle case final subtitle?) ...[
          const SizedBox(height: 5),
          Text(subtitle, style: Theme.of(context).textTheme.titleLarge),
        ],
        if (work.series case final series?) ...[
          const SizedBox(height: 7),
          Text(
            work.seriesSequence == null
                ? series
                : '$series · Band ${_formatSequence(work.seriesSequence!)}',
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ],
        const SizedBox(height: 16),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final author in authors)
              ActionChip(
                avatar: const Icon(Icons.edit_outlined, size: 17),
                label: Text(author),
                tooltip: 'Hörbücher von $author anzeigen',
                onPressed: onSelectAuthor == null
                    ? null
                    : () => onSelectAuthor!(author),
              ),
            for (final narrator in work.narrators)
              ActionChip(
                avatar: const Icon(Icons.mic_none, size: 17),
                label: Text(narrator),
                tooltip: 'Von $narrator gesprochene Hörbücher anzeigen',
                onPressed: onSelectNarrator == null
                    ? null
                    : () => onSelectNarrator!(narrator),
              ),
            if (work.language case final language?)
              Chip(label: Text(_displayLanguage(language))),
            if (work.publisher case final publisher?)
              Chip(
                label: Text(
                  work.publishedYear == null
                      ? publisher
                      : '$publisher · ${work.publishedYear}',
                ),
              )
            else if (work.publishedYear case final year?)
              Chip(label: Text('$year')),
            if (!work.available)
              Chip(
                avatar: const Icon(Icons.warning_amber_rounded, size: 18),
                label: const Text('Dateien fehlen'),
                backgroundColor: Theme.of(context).colorScheme.errorContainer,
              )
            else
              Chip(label: Text('${work.fileCount} Datei(en)')),
          ],
        ),
        const SizedBox(height: 18),
        _ProgressLabel(work: work, player: player),
        const SizedBox(height: 12),
        ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 230),
          child: FilledButton.icon(
            onPressed: playbackEnabled ? onTogglePlayback : null,
            icon: Icon(playing ? Icons.pause : Icons.play_arrow),
            label: Text(playing ? 'Pause' : 'Weiterhören'),
          ),
        ),
        if (work.description case final description?) ...[
          const SizedBox(height: 24),
          Text('Beschreibung', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          SelectableText(
            description,
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(height: 1.5),
          ),
        ],
        if (directoryPath case final path?) ...[
          const SizedBox(height: 22),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.only(top: 2),
                child: Icon(Icons.folder_outlined, size: 18),
              ),
              const SizedBox(width: 7),
              Expanded(
                child: SelectableText(
                  path,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

class _AudioCompatibilityPanel extends StatelessWidget {
  const _AudioCompatibilityPanel({required this.tracks});

  final List<LibraryPlaybackTrack> tracks;

  @override
  Widget build(BuildContext context) {
    final androidWarnings = tracks.where((track) {
      final status = track.audioMetadata
          ?.assess(AudioPlaybackTarget.android)
          .status;
      return status != null && status != AudioCompatibilityStatus.compatible;
    }).length;
    final unknown = tracks.where((track) => track.audioMetadata == null).length;
    final hasAttention = androidWarnings > 0 || unknown > 0;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        initiallyExpanded: hasAttention,
        leading: Icon(
          hasAttention ? Icons.warning_amber_rounded : Icons.task_alt,
        ),
        title: const Text('Audio-Kompatibilität'),
        subtitle: Text(
          hasAttention
              ? [
                  if (androidWarnings > 0)
                    '$androidWarnings Android-Hinweis(e)',
                  if (unknown > 0) '$unknown noch nicht analysiert',
                ].join(' · ')
              : 'Alle ${tracks.length} Datei(en) für Desktop und Android geeignet',
        ),
        children: [
          for (final track in tracks) _technicalFile(track),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 4, 16, 14),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Die Prüfung verändert keine Quelldatei. Unbekannte Formate '
                'können nach einem erneuten Bibliotheksscan bewertet werden.',
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _technicalFile(LibraryPlaybackTrack track) {
    final metadata = track.audioMetadata;
    if (metadata == null) {
      return ListTile(
        leading: const Icon(Icons.help_outline),
        title: Text(track.title),
        subtitle: const Text('Technische Daten noch nicht erfasst.'),
      );
    }
    final desktop = metadata.assess(AudioPlaybackTarget.desktop);
    final android = metadata.assess(AudioPlaybackTarget.android);
    final details = <String>[
      metadata.container,
      metadata.codec,
      ?metadata.profile,
      if (metadata.channels case final value?)
        value == 1 ? 'Mono' : '$value Kanäle',
      if (metadata.sampleRateHz case final value?) _sampleRate(value),
    ];
    return ListTile(
      isThreeLine: true,
      leading: Icon(_statusIcon(android.status)),
      title: Text(track.title),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(details.join(' · ')),
          const SizedBox(height: 5),
          Wrap(
            spacing: 6,
            runSpacing: 5,
            children: [
              _targetChip('Desktop', desktop),
              _targetChip('Android', android),
            ],
          ),
          if (android.status != AudioCompatibilityStatus.compatible) ...[
            const SizedBox(height: 4),
            Text(android.reason),
          ],
        ],
      ),
    );
  }

  Widget _targetChip(String target, AudioCompatibilityAssessment assessment) {
    return Chip(
      visualDensity: VisualDensity.compact,
      avatar: Icon(_statusIcon(assessment.status), size: 16),
      label: Text('$target: ${_statusLabel(assessment.status)}'),
    );
  }

  static IconData _statusIcon(AudioCompatibilityStatus status) =>
      switch (status) {
        AudioCompatibilityStatus.compatible => Icons.check_circle_outline,
        AudioCompatibilityStatus.warning => Icons.warning_amber_rounded,
        AudioCompatibilityStatus.unsupported => Icons.error_outline,
        AudioCompatibilityStatus.unknown => Icons.help_outline,
      };

  static String _statusLabel(AudioCompatibilityStatus status) =>
      switch (status) {
        AudioCompatibilityStatus.compatible => 'geeignet',
        AudioCompatibilityStatus.warning => 'prüfen',
        AudioCompatibilityStatus.unsupported => 'nicht geeignet',
        AudioCompatibilityStatus.unknown => 'unbekannt',
      };

  static String _sampleRate(int value) {
    if (value % 1000 == 0) return '${value ~/ 1000} kHz';
    return '${(value / 1000).toStringAsFixed(1)} kHz';
  }
}

class _DetailPanel extends StatefulWidget {
  const _DetailPanel({
    required this.work,
    this.library,
    this.player,
    this.onPlay,
    this.onDeleteMissingWork,
    this.onMetadataChanged,
    this.onSelectAuthor,
    this.onSelectNarrator,
  });

  final LibraryWorkSummary? work;
  final FundusLibrary? library;
  final FundusPlayerController? player;
  final WorkPlaybackCallback? onPlay;
  final MissingWorkDeleteCallback? onDeleteMissingWork;
  final WorkMetadataChangedCallback? onMetadataChanged;
  final ValueChanged<String>? onSelectAuthor;
  final ValueChanged<String>? onSelectNarrator;

  @override
  State<_DetailPanel> createState() => _DetailPanelState();
}

class _DetailPanelState extends State<_DetailPanel> {
  final _noteController = TextEditingController();
  WorkAnnotations _annotations = const WorkAnnotations();
  bool _saving = false;
  bool _bookmarkAvailable = false;
  bool _workIsCurrent = false;
  bool _workIsPlaying = false;
  bool _workIsQueued = false;
  LibraryWorkSummary? _editedWork;

  @override
  void initState() {
    super.initState();
    _load();
    _attachPlayer();
  }

  @override
  void didUpdateWidget(covariant _DetailPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.work?.id != widget.work?.id ||
        oldWidget.library != widget.library) {
      _editedWork = null;
      _load();
    }
    if (oldWidget.player != widget.player) {
      oldWidget.player?.removeListener(_syncPlayer);
      _attachPlayer();
    } else {
      _syncPlayer(notify: false);
    }
  }

  @override
  void dispose() {
    widget.player?.removeListener(_syncPlayer);
    _noteController.dispose();
    super.dispose();
  }

  void _load() {
    final work = widget.work;
    final library = widget.library;
    _annotations = work == null || library == null
        ? const WorkAnnotations()
        : library.loadAnnotations(work.id);
    _noteController.clear();
  }

  void _attachPlayer() {
    widget.player?.addListener(_syncPlayer);
    _syncPlayer(notify: false);
  }

  void _syncPlayer({bool notify = true}) {
    final current =
        widget.library != null &&
        widget.player?.work?.id == widget.work?.id &&
        widget.player?.track != null;
    final playing = current && (widget.player?.playing ?? false);
    final queued =
        widget.player?.queue.any((item) => item.id == widget.work?.id) ?? false;
    if (current == _bookmarkAvailable &&
        current == _workIsCurrent &&
        playing == _workIsPlaying &&
        queued == _workIsQueued) {
      return;
    }
    if (notify && mounted) {
      setState(() {
        _bookmarkAvailable = current;
        _workIsCurrent = current;
        _workIsPlaying = playing;
        _workIsQueued = queued;
      });
    } else {
      _bookmarkAvailable = current;
      _workIsCurrent = current;
      _workIsPlaying = playing;
      _workIsQueued = queued;
    }
  }

  Future<void> _togglePlayback(LibraryWorkSummary work) async {
    if (_workIsCurrent) {
      await widget.player?.playOrPause();
      return;
    }
    await widget.onPlay?.call(work);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.work == null) return const _EmptyLibrary();
    final selectedWork = _editedWork ?? widget.work!;
    final canBookmark = _bookmarkAvailable;
    final directoryPath = widget.library?.workDirectoryPath(selectedWork.id);
    final technicalTracks = selectedWork.available
        ? widget.library?.playbackTracks(selectedWork.id)
        : null;
    return ListView(
      key: const ValueKey('detail-panel-scroll'),
      padding: const EdgeInsets.all(20),
      children: [
        _AudiobookHero(
          work: selectedWork,
          player: widget.player,
          directoryPath: directoryPath,
          playing: _workIsPlaying,
          playbackEnabled:
              selectedWork.available &&
              (widget.onPlay != null || _workIsCurrent),
          onTogglePlayback: () => _togglePlayback(selectedWork),
          onSelectAuthor: widget.onSelectAuthor,
          onSelectNarrator: widget.onSelectNarrator,
        ),
        const SizedBox(height: 10),
        Align(
          alignment: Alignment.centerRight,
          child: OutlinedButton.icon(
            onPressed:
                widget.library == null || widget.library!.isReadOnly || _saving
                ? null
                : () => _editMetadata(selectedWork),
            icon: const Icon(Icons.edit_outlined),
            label: const Text('Metadaten bearbeiten'),
          ),
        ),
        if (!selectedWork.available) ...[
          const SizedBox(height: 16),
          Card(
            color: Theme.of(context).colorScheme.errorContainer,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.warning_amber_rounded),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Mediendateien nicht verfügbar',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Fundus behält Metadaten, Fortschritt, Tags, Notizen und '
                    'Lesezeichen. Stelle den Datenträger oder Ordner wieder '
                    'bereit und scanne die Bibliothek erneut.',
                  ),
                  if (widget.onDeleteMissingWork != null) ...[
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      onPressed: _saving
                          ? null
                          : () => _confirmDeleteMissingWork(selectedWork),
                      icon: const Icon(Icons.delete_outline),
                      label: const Text('Fehlenden Eintrag bereinigen'),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
        if (technicalTracks != null && technicalTracks.isNotEmpty) ...[
          const SizedBox(height: 16),
          _AudioCompatibilityPanel(tracks: technicalTracks),
        ],
        if (widget.library != null && widget.player != null) ...[
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: !selectedWork.available || _workIsQueued
                  ? null
                  : () => widget.player!.addToQueue(
                      widget.library!,
                      selectedWork,
                    ),
              icon: Icon(
                _workIsQueued ? Icons.playlist_add_check : Icons.playlist_add,
              ),
              label: Text(
                _workIsQueued ? 'In aktueller Playlist' : 'Zur Playlist',
              ),
            ),
          ),
        ],
        const SizedBox(height: 20),
        Row(
          children: [
            Text('Tags', style: Theme.of(context).textTheme.titleSmall),
            const Spacer(),
            IconButton(
              onPressed: widget.library == null || _saving ? null : _addTag,
              tooltip: 'Tag hinzufügen',
              icon: const Icon(Icons.add, size: 20),
            ),
          ],
        ),
        const SizedBox(height: 6),
        if (_annotations.tags.isEmpty)
          Text(
            'Noch keine Tags vergeben.',
            style: Theme.of(context).textTheme.bodySmall,
          )
        else
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final tag in _annotations.tags)
                InputChip(
                  label: Text('#$tag'),
                  onDeleted: _saving ? null : () => _removeTag(tag),
                ),
            ],
          ),
        const SizedBox(height: 20),
        Row(
          children: [
            Text('Lesezeichen', style: Theme.of(context).textTheme.titleSmall),
            const Spacer(),
            IconButton(
              onPressed: canBookmark && !_saving ? _addBookmark : null,
              tooltip: canBookmark
                  ? 'Aktuelle Position merken'
                  : 'Hörbuch starten, um die Position zu merken',
              icon: const Icon(Icons.bookmark_add_outlined, size: 20),
            ),
          ],
        ),
        const SizedBox(height: 6),
        if (_annotations.bookmarks.isEmpty)
          Text(
            'Noch keine Lesezeichen vorhanden.',
            style: Theme.of(context).textTheme.bodySmall,
          )
        else
          for (final bookmark in _annotations.bookmarks)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              onTap: _saving ? null : () => _jumpToBookmark(bookmark),
              leading: Text(_time(bookmark.position)),
              title: Text(bookmark.label ?? 'Lesezeichen'),
              subtitle: bookmark.note == null ? null : Text(bookmark.note!),
              trailing: IconButton(
                onPressed: _saving ? null : () => _deleteBookmark(bookmark.id),
                tooltip: 'Lesezeichen löschen',
                icon: const Icon(Icons.delete_outline, size: 20),
              ),
            ),
        const SizedBox(height: 20),
        Text('Notizen', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 6),
        if (_annotations.notes.isEmpty)
          Text(
            'Noch keine Notizen vorhanden.',
            style: Theme.of(context).textTheme.bodySmall,
          )
        else
          for (final note in _annotations.notes)
            Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _dateTime(note.createdAt),
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                    const SizedBox(height: 6),
                    SelectableText(note.markdown),
                  ],
                ),
              ),
            ),
        const SizedBox(height: 8),
        TextField(
          key: const ValueKey('note-input'),
          controller: _noteController,
          enabled: widget.library != null && !_saving,
          minLines: 3,
          maxLines: 8,
          decoration: const InputDecoration(
            hintText: 'Notiz in Markdown schreiben …',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton.tonalIcon(
            onPressed: widget.library == null || _saving ? null : _saveNote,
            icon: _saving
                ? const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.save_outlined),
            label: const Text('Notiz speichern'),
          ),
        ),
      ],
    );
  }

  Future<void> _editMetadata(LibraryWorkSummary work) async {
    final library = widget.library;
    if (library == null || library.isReadOnly) return;
    final input = await showDialog<_WorkMetadataInput>(
      context: context,
      builder: (context) => _WorkMetadataDialog(work: work),
    );
    if (input == null || !mounted) return;
    setState(() => _saving = true);
    try {
      final updated = await library.updateWorkMetadata(
        workId: work.id,
        title: input.title,
        subtitle: input.subtitle,
        authors: input.authors,
        series: input.series,
        seriesSequence: input.seriesSequence,
        narrators: input.narrators,
        language: input.language,
        description: input.description,
        publisher: input.publisher,
        publishedYear: input.publishedYear,
      );
      if (!mounted) return;
      setState(() => _editedWork = updated);
      widget.onMetadataChanged?.call(updated);
      unawaited(
        FundusDiagnostics.instance.record('library.metadata_updated', {
          'work_id': work.id,
          'author_count': updated.authors.length,
          'narrator_count': updated.narrators.length,
          'has_series': updated.series != null,
          'has_description': updated.description != null,
        }),
      );
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Metadaten gespeichert und portabel gespiegelt.'),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Metadaten konnten nicht gespeichert werden: $error'),
        ),
      );
      unawaited(
        FundusDiagnostics.instance.record('library.metadata_update_failed', {
          'work_id': work.id,
          'error': error.runtimeType.toString(),
        }),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _confirmDeleteMissingWork(LibraryWorkSummary work) async {
    final callback = widget.onDeleteMissingWork;
    if (callback == null || work.available) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Fehlenden Eintrag bereinigen?'),
        content: Text(
          '„${work.title}“ wird aus dem Fundus-Index entfernt. Dabei werden '
          'auch Fortschritt, Tags, Notizen und Lesezeichen dieses Eintrags '
          'gelöscht. Mediendateien auf Datenträgern werden nicht verändert.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Endgültig bereinigen'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _saving = true);
    try {
      await callback(work);
      if (mounted && Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _addTag() async {
    final existing = widget.library?.listTags() ?? const <String>[];
    TextEditingController? fieldController;
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Tag hinzufügen'),
        content: SizedBox(
          width: 380,
          child: Autocomplete<String>(
            optionsBuilder: (value) {
              final assigned = _annotations.tags
                  .map((tag) => tag.toLowerCase())
                  .toSet();
              return existing.where(
                (tag) =>
                    !assigned.contains(tag.toLowerCase()) &&
                    LibraryFuzzySearch.matches(tag, value.text),
              );
            },
            onSelected: (value) => Navigator.pop(context, value),
            fieldViewBuilder:
                (context, controller, focusNode, onFieldSubmitted) {
                  fieldController = controller;
                  return TextField(
                    controller: controller,
                    focusNode: focusNode,
                    autofocus: true,
                    decoration: const InputDecoration(
                      labelText: 'Tag suchen oder neu anlegen',
                      hintText: 'z. B. Fantasy',
                      prefixIcon: Icon(Icons.search),
                    ),
                    onSubmitted: (value) => Navigator.pop(context, value),
                  );
                },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, fieldController?.text),
            child: const Text('Hinzufügen'),
          ),
        ],
      ),
    );
    if (value == null || value.trim().isEmpty) return;
    await _updateTags({..._annotations.tags, value.trim()});
  }

  Future<void> _removeTag(String tag) async {
    await _updateTags(_annotations.tags.where((value) => value != tag));
  }

  Future<void> _updateTags(Iterable<String> tags) async {
    final library = widget.library;
    final work = widget.work;
    if (library == null || work == null) return;
    await _runSave(() => library.replaceWorkTags(work.id, tags));
  }

  Future<void> _saveNote() async {
    final library = widget.library;
    final work = widget.work;
    if (library == null || work == null) return;
    final markdown = _noteController.text.trim();
    if (markdown.isEmpty) return;
    _noteController.clear();
    final saved = await _runSave(
      () => library.saveWorkNote(work.id, markdown),
      successMessage: 'Notiz gespeichert.',
    );
    if (!saved && mounted) _noteController.text = markdown;
  }

  Future<void> _addBookmark() async {
    final library = widget.library;
    final work = widget.work;
    final player = widget.player;
    final track = player?.track;
    if (library == null || work == null || player == null || track == null) {
      return;
    }
    final controller = TextEditingController();
    final label = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Lesezeichen bei ${_time(player.position)}'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Bezeichnung (optional)',
          ),
          onSubmitted: (value) => Navigator.pop(context, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Speichern'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (label == null) return;
    await _runSave(
      () => library.addBookmark(
        workId: work.id,
        fileId: track.fileId,
        position: player.position,
        label: label,
      ),
      successMessage: 'Lesezeichen gespeichert.',
    );
  }

  Future<void> _deleteBookmark(String bookmarkId) async {
    final library = widget.library;
    final work = widget.work;
    if (library == null || work == null) return;
    await _runSave(() => library.deleteBookmark(work.id, bookmarkId));
  }

  Future<void> _jumpToBookmark(LibraryBookmark bookmark) async {
    final library = widget.library;
    final selectedWork = widget.work;
    final onPlay = widget.onPlay;
    if (library == null || selectedWork == null || onPlay == null) return;

    final player = widget.player;
    final currentWork = player?.work;
    final currentTrack = player?.track;
    final sameBookmarkPosition =
        currentWork?.id == selectedWork.id &&
        (bookmark.fileId == null || bookmark.fileId == currentTrack?.fileId) &&
        player != null &&
        (player.position - bookmark.position).abs() <=
            const Duration(seconds: 2);
    final hasReturnPosition =
        !sameBookmarkPosition &&
        currentWork != null &&
        currentTrack != null &&
        player!.position > Duration.zero;
    var action = _BookmarkJumpAction.jumpDirectly;
    if (hasReturnPosition) {
      final selected = await showDialog<_BookmarkJumpAction>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(
            'Zu „${bookmark.label ?? _time(bookmark.position)}“ springen?',
          ),
          content: Text(
            'Die aktuelle Position bei ${_time(player.position)} kann vorher als Rücksprung-Lesezeichen gespeichert werden.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Abbrechen'),
            ),
            TextButton(
              onPressed: () =>
                  Navigator.pop(context, _BookmarkJumpAction.jumpDirectly),
              child: const Text('Direkt springen'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.pop(context, _BookmarkJumpAction.rememberAndJump),
              child: const Text('Position merken & springen'),
            ),
          ],
        ),
      );
      if (selected == null) return;
      action = selected;
    }

    setState(() => _saving = true);
    try {
      if (action == _BookmarkJumpAction.rememberAndJump &&
          currentWork != null &&
          currentTrack != null &&
          player != null) {
        await library.addBookmark(
          workId: currentWork.id,
          fileId: currentTrack.fileId,
          position: player.position,
          label: 'Rücksprung vor ${bookmark.label ?? _time(bookmark.position)}',
        );
      }
      if (player?.work?.id == selectedWork.id) {
        await player!.jumpToBookmark(bookmark);
      } else {
        await onPlay(
          selectedWork,
          startFileId: bookmark.fileId,
          startPosition: bookmark.position,
        );
      }
      if (!mounted) return;
      setState(_load);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Sprung fehlgeschlagen: $error')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<bool> _runSave(
    Future<WorkAnnotations> Function() action, {
    String? successMessage,
  }) async {
    setState(() => _saving = true);
    try {
      final annotations = await action();
      if (!mounted) return false;
      setState(() {
        _annotations = annotations;
      });
      if (successMessage != null) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(successMessage)));
      }
      return true;
    } catch (error) {
      if (!mounted) return false;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Speichern fehlgeschlagen: $error')),
      );
      return false;
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  static String _time(Duration value) {
    final hours = value.inHours.toString().padLeft(2, '0');
    final minutes = (value.inMinutes % 60).toString().padLeft(2, '0');
    final seconds = (value.inSeconds % 60).toString().padLeft(2, '0');
    return '$hours:$minutes:$seconds';
  }

  static String _dateTime(DateTime value) {
    final local = value.toLocal();
    return '${local.day.toString().padLeft(2, '0')}.'
        '${local.month.toString().padLeft(2, '0')}.${local.year}, '
        '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')} Uhr';
  }
}

final class _WorkMetadataInput {
  const _WorkMetadataInput({
    required this.title,
    required this.authors,
    required this.narrators,
    this.subtitle,
    this.series,
    this.seriesSequence,
    this.language,
    this.description,
    this.publisher,
    this.publishedYear,
  });

  final String title;
  final List<String> authors;
  final String? subtitle;
  final String? series;
  final double? seriesSequence;
  final List<String> narrators;
  final String? language;
  final String? description;
  final String? publisher;
  final int? publishedYear;
}

class _WorkMetadataDialog extends StatefulWidget {
  const _WorkMetadataDialog({required this.work});

  final LibraryWorkSummary work;

  @override
  State<_WorkMetadataDialog> createState() => _WorkMetadataDialogState();
}

class _WorkMetadataDialogState extends State<_WorkMetadataDialog> {
  late final TextEditingController _title;
  late final TextEditingController _subtitle;
  late final TextEditingController _authors;
  late final TextEditingController _series;
  late final TextEditingController _sequence;
  late final TextEditingController _narrators;
  late final TextEditingController _language;
  late final TextEditingController _publisher;
  late final TextEditingController _year;
  late final TextEditingController _description;
  String? _error;

  @override
  void initState() {
    super.initState();
    final work = widget.work;
    _title = TextEditingController(text: work.title);
    _subtitle = TextEditingController(text: work.subtitle ?? '');
    _authors = TextEditingController(text: work.authors.join(', '));
    _series = TextEditingController(text: work.series ?? '');
    _sequence = TextEditingController(
      text: work.seriesSequence == null
          ? ''
          : _formatSequence(work.seriesSequence!),
    );
    _narrators = TextEditingController(text: work.narrators.join(', '));
    _language = TextEditingController(text: work.language ?? '');
    _publisher = TextEditingController(text: work.publisher ?? '');
    _year = TextEditingController(text: work.publishedYear?.toString() ?? '');
    _description = TextEditingController(text: work.description ?? '');
  }

  @override
  void dispose() {
    for (final controller in [
      _title,
      _subtitle,
      _authors,
      _series,
      _sequence,
      _narrators,
      _language,
      _publisher,
      _year,
      _description,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Hörbuch-Metadaten bearbeiten'),
    content: SizedBox(
      width: 620,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _field(_title, 'Titel', required: true, originKey: 'title'),
            _field(_subtitle, 'Untertitel', originKey: 'subtitle'),
            _field(
              _authors,
              'Autor(en)',
              required: true,
              originKey: 'authors',
              hint: 'Mehrere mit Komma oder neuer Zeile trennen',
            ),
            Row(
              children: [
                Expanded(child: _field(_series, 'Serie', originKey: 'series')),
                const SizedBox(width: 12),
                SizedBox(
                  width: 120,
                  child: _field(
                    _sequence,
                    'Band',
                    originKey: 'series_sequence',
                  ),
                ),
              ],
            ),
            _field(
              _narrators,
              'Sprecher',
              originKey: 'narrators',
              hint: 'Mehrere mit Komma oder neuer Zeile trennen',
            ),
            Row(
              children: [
                Expanded(
                  child: _field(_language, 'Sprache', originKey: 'language'),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _field(_publisher, 'Verlag', originKey: 'publisher'),
                ),
                const SizedBox(width: 12),
                SizedBox(
                  width: 110,
                  child: _field(_year, 'Jahr', originKey: 'published_year'),
                ),
              ],
            ),
            _field(
              _description,
              'Beschreibung',
              originKey: 'description',
              minLines: 4,
              maxLines: 10,
            ),
            if (_error case final error?) ...[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  error,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            ],
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Abbrechen'),
      ),
      FilledButton.icon(
        onPressed: _submit,
        icon: const Icon(Icons.save_outlined),
        label: const Text('Speichern'),
      ),
    ],
  );

  Widget _field(
    TextEditingController controller,
    String label, {
    bool required = false,
    String? hint,
    String? originKey,
    int minLines = 1,
    int maxLines = 1,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: TextField(
      controller: controller,
      minLines: minLines,
      maxLines: maxLines,
      decoration: InputDecoration(
        labelText: required ? '$label *' : label,
        hintText: hint,
        helperText: originKey == null ? null : _originLabel(originKey),
        border: const OutlineInputBorder(),
      ),
    ),
  );

  String? _originLabel(String key) {
    final origin = widget.work.metadataOrigins[key];
    if (origin == null) return 'Quelle: bisher nicht erfasst';
    final source = switch (origin.source) {
      WorkMetadataSource.user => 'manuell',
      WorkMetadataSource.online => 'Online-Abgleich',
      WorkMetadataSource.sidecar => 'Fundus-Sidecar',
      WorkMetadataSource.abs => 'Audiobookshelf',
      WorkMetadataSource.embedded => 'Datei-Tags',
      WorkMetadataSource.filename => 'Datei-/Ordnername',
    };
    final local = origin.updatedAt.toLocal();
    final date =
        '${local.day.toString().padLeft(2, '0')}.'
        '${local.month.toString().padLeft(2, '0')}.'
        '${local.year} '
        '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
    return 'Quelle: $source · $date';
  }

  void _submit() {
    final authors = _splitPeople(_authors.text);
    final sequence = _nullableDouble(_sequence.text);
    final year = _nullableInt(_year.text);
    if (_title.text.trim().isEmpty || authors.isEmpty) {
      setState(
        () => _error = 'Titel und mindestens ein Autor sind erforderlich.',
      );
      return;
    }
    if (_sequence.text.trim().isNotEmpty && sequence == null) {
      setState(() => _error = 'Die Bandnummer muss eine Zahl sein.');
      return;
    }
    if (_year.text.trim().isNotEmpty && year == null) {
      setState(
        () => _error = 'Das Erscheinungsjahr muss eine ganze Zahl sein.',
      );
      return;
    }
    Navigator.pop(
      context,
      _WorkMetadataInput(
        title: _title.text.trim(),
        subtitle: _nullable(_subtitle.text),
        authors: authors,
        series: _nullable(_series.text),
        seriesSequence: sequence,
        narrators: _splitPeople(_narrators.text),
        language: _nullable(_language.text),
        description: _nullable(_description.text),
        publisher: _nullable(_publisher.text),
        publishedYear: year,
      ),
    );
  }

  static List<String> _splitPeople(String value) => value
      .split(RegExp(r'[,;\n]+'))
      .map((item) => item.trim())
      .where((item) => item.isNotEmpty)
      .toSet()
      .toList(growable: false);

  static String? _nullable(String value) =>
      value.trim().isEmpty ? null : value.trim();

  static double? _nullableDouble(String value) => value.trim().isEmpty
      ? null
      : double.tryParse(value.trim().replaceAll(',', '.'));

  static int? _nullableInt(String value) =>
      value.trim().isEmpty ? null : int.tryParse(value.trim());
}

enum _BookmarkJumpAction { jumpDirectly, rememberAndJump }

class _WorkCover extends StatelessWidget {
  const _WorkCover({required this.work, required this.iconSize, this.player});

  final LibraryWorkSummary work;
  final double iconSize;
  final FundusPlayerController? player;

  @override
  Widget build(BuildContext context) {
    final controller = player;
    if (controller != null) {
      return AnimatedBuilder(
        animation: controller,
        builder: (context, child) => _coverWithProgress(context),
      );
    }
    return _coverWithProgress(context);
  }

  Widget _coverWithProgress(BuildContext context) {
    final progress = _progressFor(work, player);
    final artwork = _artwork();
    if (progress == null) return artwork;
    return Stack(
      fit: StackFit.expand,
      children: [
        artwork,
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: ColoredBox(
            color: Colors.black.withValues(alpha: .72),
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                iconSize < 30 ? 2 : 7,
                iconSize < 30 ? 2 : 5,
                iconSize < 30 ? 2 : 7,
                3,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (iconSize >= 30)
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        progress.label,
                        maxLines: 1,
                        style: Theme.of(
                          context,
                        ).textTheme.labelSmall?.copyWith(color: Colors.white),
                      ),
                    ),
                  LinearProgressIndicator(
                    value: progress.fraction,
                    minHeight: iconSize < 30 ? 3 : 4,
                    backgroundColor: Colors.white24,
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _artwork() {
    final path = work.coverPath;
    if (path == null || path.isEmpty) return _placeholder();
    return Image.file(
      File(path),
      fit: BoxFit.cover,
      filterQuality: FilterQuality.medium,
      errorBuilder: (context, error, stackTrace) => _placeholder(),
    );
  }

  Widget _placeholder() =>
      Center(child: Icon(Icons.music_note, size: iconSize));
}

class _ProgressLabel extends StatelessWidget {
  const _ProgressLabel({required this.work, this.player});

  final LibraryWorkSummary work;
  final FundusPlayerController? player;

  @override
  Widget build(BuildContext context) {
    final controller = player;
    if (controller == null) return _label();
    return AnimatedBuilder(animation: controller, builder: (_, _) => _label());
  }

  Widget _label() {
    final progress = _progressFor(work, player);
    return Text(progress?.label ?? '—');
  }
}

({double fraction, String label})? _progressFor(
  LibraryWorkSummary work,
  FundusPlayerController? player,
) {
  final current = player?.work?.id == work.id;
  final session = player?.progressForWork(work.id);
  final position = current
      ? player!.position
      : session?.position ?? work.progressPosition;
  final duration = current && player!.duration > Duration.zero
      ? player.duration
      : session?.duration ?? work.progressDuration;
  if (position == null || position <= Duration.zero) return null;
  final finished = !current && (session?.finished ?? work.progressFinished);
  final fraction = finished
      ? 1.0
      : duration == null || duration <= Duration.zero
      ? 0.0
      : (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0);
  final trackIndex = current
      ? player!.currentIndex
      : session?.trackIndex ?? work.progressTrackIndex;
  final trackPrefix = work.fileCount > 1 && trackIndex != null
      ? 'Datei ${trackIndex + 1}/${work.fileCount} · '
      : '';
  if (duration == null || duration <= Duration.zero) {
    return (
      fraction: fraction,
      label: '${trackPrefix}gehört ${_progressTime(position)}',
    );
  }
  final remaining = duration > position ? duration - position : Duration.zero;
  return (
    fraction: fraction,
    label:
        '$trackPrefix${_progressTime(position)} / ${_progressTime(duration)} · Rest ${_progressTime(remaining)}',
  );
}

String _progressTime(Duration value) {
  final hours = value.inHours.toString().padLeft(2, '0');
  final minutes = (value.inMinutes % 60).toString().padLeft(2, '0');
  final seconds = (value.inSeconds % 60).toString().padLeft(2, '0');
  return '$hours:$minutes:$seconds';
}

enum _PlayerContextTab { files, chapters, details, playlist }

class _ExpandedPlayer extends StatefulWidget {
  const _ExpandedPlayer({
    required this.controller,
    required this.onCollapse,
    this.library,
    this.onPlay,
    this.onSelectAuthor,
    this.onSelectNarrator,
  });

  final FundusPlayerController controller;
  final FundusLibrary? library;
  final VoidCallback onCollapse;
  final WorkPlaybackCallback? onPlay;
  final ValueChanged<String>? onSelectAuthor;
  final ValueChanged<String>? onSelectNarrator;

  @override
  State<_ExpandedPlayer> createState() => _ExpandedPlayerState();
}

class _ExpandedPlayerState extends State<_ExpandedPlayer> {
  _PlayerContextTab _tab = _PlayerContextTab.files;
  double _contextWidth = 340;
  late final PageController _mainPageController = PageController();
  int _mainPage = 0;

  @override
  void dispose() {
    _mainPageController.dispose();
    super.dispose();
  }

  Future<void> _savePlaylist() async {
    final existingName = widget.controller.playlistName;
    final nameController = TextEditingController(
      text: existingName ?? 'Neue Playlist',
    );
    final choice = await showDialog<({String name, bool overwrite})>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Playlist speichern'),
        content: TextField(
          controller: nameController,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Name'),
          onSubmitted: (value) => Navigator.pop(context, (
            name: value,
            overwrite: existingName != null,
          )),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Abbrechen'),
          ),
          if (existingName != null)
            TextButton(
              onPressed: () => Navigator.pop(context, (
                name: nameController.text,
                overwrite: false,
              )),
              child: const Text('Als neue speichern'),
            ),
          FilledButton(
            onPressed: () => Navigator.pop(context, (
              name: nameController.text,
              overwrite: existingName != null,
            )),
            child: Text(existingName == null ? 'Speichern' : 'Überschreiben'),
          ),
        ],
      ),
    );
    nameController.dispose();
    if (choice == null || choice.name.trim().isEmpty || !mounted) return;
    try {
      final saved = widget.controller.saveQueueAs(
        choice.name,
        overwrite: choice.overwrite,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Playlist „${saved.name}“ gespeichert.')),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Playlist konnte nicht gespeichert werden: $error'),
        ),
      );
    }
  }

  Future<void> _loadPlaylist(String playlistId) async {
    try {
      await widget.controller.loadSavedPlaylist(playlistId);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Playlist konnte nicht geöffnet werden: $error'),
        ),
      );
    }
  }

  Future<void> _deletePlaylist() async {
    final id = widget.controller.playlistId;
    final name = widget.controller.playlistName;
    if (id == null || name == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Playlist löschen?'),
        content: Text(
          '„$name“ wird dauerhaft gelöscht. Die aktuelle Queue bleibt erhalten.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Löschen'),
          ),
        ],
      ),
    );
    if (confirmed == true) widget.controller.deleteSavedPlaylist(id);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, child) {
        final work = widget.controller.work;
        return LayoutBuilder(
          builder: (context, constraints) {
            if (constraints.maxWidth < 760) {
              return _mobilePlayer(work);
            }
            return Row(
              children: [
                Expanded(
                  child: Column(
                    children: [
                      Align(
                        alignment: Alignment.centerRight,
                        child: IconButton(
                          onPressed: widget.onCollapse,
                          tooltip: 'Player verkleinern',
                          icon: const Icon(Icons.close_fullscreen),
                        ),
                      ),
                      Expanded(child: _mainPager(work)),
                      LayoutBuilder(
                        builder: (context, constraints) => _PlayerBar(
                          controller: widget.controller,
                          compact: constraints.maxWidth < 760,
                        ),
                      ),
                    ],
                  ),
                ),
                _ResizeHandle(
                  onDrag: (delta) => setState(
                    () =>
                        _contextWidth = (_contextWidth - delta).clamp(300, 720),
                  ),
                  onReset: () => setState(() => _contextWidth = 340),
                ),
                SizedBox(
                  width: _contextWidth,
                  child: Column(
                    children: [
                      SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.all(8),
                        child: SegmentedButton<_PlayerContextTab>(
                          segments: const [
                            ButtonSegment(
                              value: _PlayerContextTab.files,
                              icon: Icon(Icons.audio_file_outlined),
                              label: Text('Dateien'),
                            ),
                            ButtonSegment(
                              value: _PlayerContextTab.chapters,
                              icon: Icon(Icons.list_alt),
                              label: Text('Chapters'),
                            ),
                            ButtonSegment(
                              value: _PlayerContextTab.details,
                              icon: Icon(Icons.info_outline),
                              label: Text('Details'),
                            ),
                            ButtonSegment(
                              value: _PlayerContextTab.playlist,
                              icon: Icon(Icons.queue_music),
                              label: Text('Playlist'),
                            ),
                          ],
                          selected: {_tab},
                          onSelectionChanged: (selection) =>
                              setState(() => _tab = selection.first),
                        ),
                      ),
                      const Divider(height: 1),
                      Expanded(child: _context(work)),
                    ],
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _mobilePlayer(LibraryWorkSummary? work) {
    final tracks = widget.controller.tracks;
    final chapters = widget.controller.chapters;
    final authors = work == null
        ? const <String>[]
        : work.authors.isEmpty
        ? [work.author]
        : work.authors;
    final cover = AspectRatio(
      aspectRatio: 1,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: work == null
            ? const Card(child: Icon(Icons.audiotrack, size: 100))
            : _WorkCover(work: work, iconSize: 100, player: widget.controller),
      ),
    );
    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Center(child: SizedBox(width: 280, child: cover)),
              const SizedBox(height: 20),
              Text(
                work?.title ?? 'Wiedergabe',
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              if (work?.subtitle case final subtitle?) ...[
                const SizedBox(height: 6),
                Text(subtitle),
              ],
              if (authors.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(authors.join(', ')),
              ],
              if (work?.series case final series?) ...[
                const SizedBox(height: 8),
                Text(
                  work?.seriesSequence == null
                      ? series
                      : '$series · Band '
                            '${_formatSequence(work!.seriesSequence!)}',
                ),
              ],
              if (work != null &&
                  (work.narrators.isNotEmpty || work.language != null)) ...[
                const SizedBox(height: 14),
                Wrap(
                  spacing: 7,
                  runSpacing: 7,
                  children: [
                    for (final narrator in work.narrators)
                      Chip(
                        avatar: const Icon(Icons.mic_none, size: 16),
                        label: Text(narrator),
                      ),
                    if (work.language case final language?)
                      Chip(label: Text(_displayLanguage(language))),
                  ],
                ),
              ],
              if (work?.description case final description?) ...[
                const SizedBox(height: 20),
                Text(
                  'Beschreibung',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                Text(description),
              ],
              const SizedBox(height: 24),
              Text('Chapters', style: Theme.of(context).textTheme.titleMedium),
              if (chapters.isEmpty)
                const ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text('Keine Chapters gefunden.'),
                )
              else
                for (var index = 0; index < chapters.length; index++)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    selected: index == widget.controller.currentChapterIndex,
                    leading: Text('${index + 1}'),
                    title: Text(chapters[index].title),
                    subtitle: Text(_chapterSubtitle(chapters[index])),
                    trailing: index == widget.controller.currentChapterIndex
                        ? const Icon(Icons.graphic_eq)
                        : null,
                    onTap: () =>
                        widget.controller.jumpToChapter(chapters[index]),
                  ),
              const SizedBox(height: 24),
              Text('Dateien', style: Theme.of(context).textTheme.titleMedium),
              for (var index = 0; index < tracks.length; index++)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  selected: index == widget.controller.currentIndex,
                  leading: Text('${index + 1}'),
                  title: Text(tracks[index].title),
                  subtitle: _mobileTrackSubtitle(tracks[index]),
                  trailing: index == widget.controller.currentIndex
                      ? const Icon(Icons.graphic_eq)
                      : null,
                  onTap: () => widget.controller.jumpToTrack(index),
                ),
              const SizedBox(height: 24),
            ],
          ),
        ),
        SafeArea(
          top: false,
          child: _PlayerBar(controller: widget.controller, compact: true),
        ),
      ],
    );
  }

  Widget? _mobileTrackSubtitle(LibraryPlaybackTrack track) {
    final metadata = track.audioMetadata;
    final parts = <String>[
      if (metadata != null) ...[
        metadata.container,
        metadata.codec,
        ?metadata.profile,
        if (metadata.channels case final channels?)
          channels == 1 ? 'Mono' : '$channels Kanäle',
        if (metadata.sampleRateHz case final sampleRate?)
          '${(sampleRate / 1000).toStringAsFixed(sampleRate % 1000 == 0 ? 0 : 1)} kHz',
      ],
      if (track.duration case final duration?) _PlayerBar._time(duration),
    ];
    return parts.isEmpty ? null : Text(parts.join(' · '));
  }

  Widget _mainPager(LibraryWorkSummary? work) {
    const labels = ['Player', 'Chapters', 'Details'];
    return Column(
      children: [
        Text(labels[_mainPage], style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (var index = 0; index < labels.length; index++)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 3),
                child: Icon(
                  index == _mainPage ? Icons.circle : Icons.circle_outlined,
                  size: 9,
                ),
              ),
          ],
        ),
        Expanded(
          child: Stack(
            children: [
              PageView(
                controller: _mainPageController,
                onPageChanged: (page) => setState(() => _mainPage = page),
                children: [
                  _artworkPage(work),
                  _chapterList(),
                  _detailsPage(work),
                ],
              ),
              if (_mainPage > 0)
                Align(
                  alignment: Alignment.centerLeft,
                  child: IconButton.filledTonal(
                    onPressed: () => _showMainPage(_mainPage - 1),
                    tooltip: labels[_mainPage - 1],
                    icon: const Icon(Icons.chevron_left),
                  ),
                ),
              if (_mainPage < labels.length - 1)
                Align(
                  alignment: Alignment.centerRight,
                  child: IconButton.filledTonal(
                    onPressed: () => _showMainPage(_mainPage + 1),
                    tooltip: labels[_mainPage + 1],
                    icon: const Icon(Icons.chevron_right),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  void _showMainPage(int page) => _mainPageController.animateToPage(
    page,
    duration: const Duration(milliseconds: 220),
    curve: Curves.easeOut,
  );

  Widget _artworkPage(LibraryWorkSummary? work) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 900),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox.square(
            dimension: 260,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(18),
              child: work == null
                  ? const Icon(Icons.headphones, size: 96)
                  : _WorkCover(
                      work: work,
                      iconSize: 96,
                      player: widget.controller,
                    ),
            ),
          ),
          const SizedBox(height: 22),
          Text(
            work?.title ?? 'Wiedergabe',
            style: Theme.of(context).textTheme.headlineSmall,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 4),
          Text(
            widget.controller.track?.title ?? '',
            textAlign: TextAlign.center,
          ),
        ],
      ),
    ),
  );

  Widget _detailsPage(LibraryWorkSummary? work) {
    if (work == null) {
      return const Center(child: Text('Keine Details verfügbar.'));
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(48, 20, 48, 28),
      children: [
        _AudiobookHero(
          work: work,
          directoryPath: widget.library?.workDirectoryPath(work.id),
          player: widget.controller,
          playing: widget.controller.playing,
          playbackEnabled: true,
          onTogglePlayback: widget.controller.playOrPause,
          onSelectAuthor: widget.onSelectAuthor,
          onSelectNarrator: widget.onSelectNarrator,
        ),
      ],
    );
  }

  Widget _context(LibraryWorkSummary? work) => switch (_tab) {
    _PlayerContextTab.files => _trackList('Dateien'),
    _PlayerContextTab.playlist => _playlist(work),
    _PlayerContextTab.chapters => _chapterList(),
    _PlayerContextTab.details => _DetailPanel(
      work: work,
      library: widget.library,
      player: widget.controller,
      onPlay: widget.onPlay,
      onSelectAuthor: widget.onSelectAuthor,
      onSelectNarrator: widget.onSelectNarrator,
    ),
  };

  Widget _playlist(LibraryWorkSummary? work) {
    final queue = widget.controller.queue;
    final savedPlaylists = widget.controller.savedPlaylists;
    if (queue.isEmpty) return const Center(child: Text('Playlist ist leer.'));
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${widget.controller.playlistName ?? 'Aktuelle Playlist'} · ${queue.length} Werk(e)',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                PopupMenuButton<String>(
                  enabled: savedPlaylists.isNotEmpty,
                  tooltip: 'Gespeicherte Playlist öffnen',
                  icon: const Icon(Icons.folder_open_outlined),
                  onSelected: _loadPlaylist,
                  itemBuilder: (context) => [
                    for (final playlist in savedPlaylists)
                      PopupMenuItem(
                        value: playlist.id,
                        child: Row(
                          children: [
                            if (playlist.id == widget.controller.playlistId)
                              const Padding(
                                padding: EdgeInsets.only(right: 8),
                                child: Icon(Icons.check, size: 18),
                              ),
                            Expanded(child: Text(playlist.name)),
                            Text('${playlist.workIds.length}'),
                          ],
                        ),
                      ),
                  ],
                ),
                IconButton(
                  onPressed: widget.library?.isReadOnly == false
                      ? _savePlaylist
                      : null,
                  tooltip: 'Playlist speichern',
                  icon: const Icon(Icons.save_outlined),
                ),
                if (widget.controller.playlistId != null)
                  IconButton(
                    onPressed: _deletePlaylist,
                    tooltip: 'Gespeicherte Playlist löschen',
                    icon: const Icon(Icons.delete_outline),
                  ),
                IconButton(
                  onPressed: queue.length < 2
                      ? null
                      : () => widget.controller.setShuffle(
                          !widget.controller.shuffleEnabled,
                        ),
                  tooltip: widget.controller.shuffleEnabled
                      ? 'Shuffle ausschalten'
                      : 'Shuffle einschalten',
                  icon: Icon(
                    Icons.shuffle,
                    color: widget.controller.shuffleEnabled
                        ? Theme.of(context).colorScheme.primary
                        : null,
                  ),
                ),
                IconButton(
                  onPressed: widget.controller.cycleRepeatMode,
                  tooltip: switch (widget.controller.repeatMode.name) {
                    'all' => 'Playlist wiederholen',
                    'one' => 'Werk wiederholen',
                    _ => 'Wiederholen aus',
                  },
                  icon: Icon(
                    widget.controller.repeatMode.name == 'one'
                        ? Icons.repeat_one
                        : Icons.repeat,
                    color: widget.controller.repeatMode.name == 'none'
                        ? null
                        : Theme.of(context).colorScheme.primary,
                  ),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 8),
        for (var index = 0; index < queue.length; index++)
          ListTile(
            selected: index == widget.controller.queueIndex,
            onTap: () => widget.controller.jumpToQueueWork(index),
            leading: SizedBox.square(
              dimension: 48,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: _WorkCover(
                  work: queue[index],
                  iconSize: 24,
                  player: widget.controller,
                ),
              ),
            ),
            title: Text(queue[index].title),
            subtitle: Text(
              '${queue[index].author} · ${queue[index].fileCount} Datei(en)',
            ),
            trailing: SizedBox(
              width: 76,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (index == widget.controller.queueIndex)
                    const Icon(Icons.graphic_eq),
                  PopupMenuButton<String>(
                    tooltip: 'Playlist-Eintrag verwalten',
                    onSelected: (action) {
                      switch (action) {
                        case 'up':
                          widget.controller.moveQueueItem(index, index - 1);
                        case 'down':
                          widget.controller.moveQueueItem(index, index + 1);
                        case 'remove':
                          widget.controller.removeFromQueue(index);
                      }
                    },
                    itemBuilder: (context) => [
                      PopupMenuItem(
                        value: 'up',
                        enabled: index > 0,
                        child: const ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(Icons.arrow_upward),
                          title: Text('Nach oben'),
                        ),
                      ),
                      PopupMenuItem(
                        value: 'down',
                        enabled: index + 1 < queue.length,
                        child: const ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(Icons.arrow_downward),
                          title: Text('Nach unten'),
                        ),
                      ),
                      PopupMenuItem(
                        value: 'remove',
                        enabled: index != widget.controller.queueIndex,
                        child: const ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(Icons.close),
                          title: Text('Entfernen'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _chapterList() {
    final chapters = widget.controller.chapters;
    if (chapters.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Für dieses Hörbuch wurden keine Chapters gefunden.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    final currentChapter = widget.controller.currentChapterIndex;
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: chapters.length + 1,
      itemBuilder: (context, index) {
        if (index == 0) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 6),
            child: Text(
              'Chapters',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          );
        }
        final chapterIndex = index - 1;
        final chapter = chapters[chapterIndex];
        final selected = chapterIndex == currentChapter;
        return ListTile(
          selected: selected,
          leading: Text('$index'),
          title: Text(
            chapter.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(_chapterSubtitle(chapter)),
          trailing: selected ? const Icon(Icons.graphic_eq) : null,
          onTap: () => widget.controller.jumpToChapter(chapter),
        );
      },
    );
  }

  String _chapterSubtitle(LibraryPlaybackChapter chapter) {
    final parts = <String>[];
    if (widget.controller.trackCount > 1) {
      parts.add('Datei ${chapter.trackIndex + 1}');
    }
    parts.add('ab ${_PlayerBar._time(chapter.position)}');
    if (chapter.duration case final duration?) {
      parts.add('Dauer ${_PlayerBar._time(duration)}');
    }
    return parts.join(' · ');
  }

  Widget _trackList(String title) => ListView.builder(
    padding: const EdgeInsets.symmetric(vertical: 8),
    itemCount: widget.controller.tracks.length + 1,
    itemBuilder: (context, index) {
      if (index == 0) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 6),
          child: Text(title, style: Theme.of(context).textTheme.titleMedium),
        );
      }
      final trackIndex = index - 1;
      final track = widget.controller.tracks[trackIndex];
      final selected = trackIndex == widget.controller.currentIndex;
      return ListTile(
        selected: selected,
        leading: Text('$index'),
        title: Text(track.title, maxLines: 2, overflow: TextOverflow.ellipsis),
        subtitle: track.duration == null
            ? null
            : Text(_PlayerBar._time(track.duration!)),
        trailing: selected ? const Icon(Icons.graphic_eq) : null,
        onTap: () => widget.controller.jumpToTrack(trackIndex),
      );
    },
  );
}

class _PlayerBar extends StatelessWidget {
  const _PlayerBar({
    required this.controller,
    this.compact = false,
    this.onExpand,
  });

  final FundusPlayerController controller;
  final bool compact;
  final VoidCallback? onExpand;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, child) {
        final work = controller.work;
        final track = controller.track;
        final maximum = controller.duration.inMilliseconds.toDouble();
        final current = controller.position.inMilliseconds
            .clamp(0, maximum > 0 ? maximum : 1)
            .toDouble();
        if (compact) {
          return Material(
            elevation: 3,
            child: SizedBox(
              height: 112,
              child: Column(
                children: [
                  SizedBox(
                    height: 56,
                    child: Row(
                      children: [
                        IconButton.filled(
                          onPressed: controller.loading
                              ? null
                              : controller.playOrPause,
                          tooltip: controller.playing ? 'Pause' : 'Abspielen',
                          icon: controller.loading
                              ? const SizedBox.square(
                                  dimension: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : Icon(
                                  controller.playing
                                      ? Icons.pause
                                      : Icons.play_arrow,
                                ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                work?.title ?? 'Wiedergabe',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              Text(
                                track?.title ?? '',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ],
                          ),
                        ),
                        PlaybackSleepTimerButton(
                          timer: controller.sleepTimer,
                          compact: true,
                          supportsChapterEnd: controller.chapters.isNotEmpty,
                        ),
                        if (onExpand != null)
                          IconButton(
                            onPressed: onExpand,
                            tooltip: 'Player vergrößern',
                            icon: const Icon(Icons.open_in_full),
                          ),
                      ],
                    ),
                  ),
                  SizedBox(
                    height: 56,
                    child: Row(
                      children: [
                        _compactButton(
                          onPressed: controller.previous,
                          tooltip: 'Vorheriger Track',
                          icon: Icons.skip_previous,
                        ),
                        _compactButton(
                          onPressed: () => controller.seekRelative(
                            const Duration(seconds: -15),
                          ),
                          tooltip: '15 Sekunden zurück',
                          icon: Icons.replay_10,
                        ),
                        Text(_time(controller.position)),
                        Expanded(
                          child: Slider(
                            value: current,
                            max: maximum > 0 ? maximum : 1,
                            onChanged: maximum <= 0
                                ? null
                                : (value) => controller.seek(
                                    Duration(milliseconds: value.round()),
                                  ),
                            onChangeEnd: maximum <= 0
                                ? null
                                : (_) => controller.persist(),
                          ),
                        ),
                        Text(_time(controller.duration)),
                        _compactButton(
                          onPressed: () => controller.seekRelative(
                            const Duration(seconds: 30),
                          ),
                          tooltip: '30 Sekunden vor',
                          icon: Icons.forward_30,
                        ),
                        _compactButton(
                          onPressed: controller.next,
                          tooltip: 'Nächster Track',
                          icon: Icons.skip_next,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        }
        return Material(
          elevation: 4,
          child: SizedBox(
            height: controller.error == null ? 88 : 112,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Column(
                children: [
                  Expanded(
                    child: Row(
                      children: [
                        SizedBox(
                          width: 210,
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                work?.title ?? 'Wiedergabe',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              Text(
                                track?.title ?? '',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          onPressed: controller.previous,
                          tooltip: 'Vorheriger Track',
                          icon: const Icon(Icons.skip_previous),
                        ),
                        IconButton(
                          onPressed: () => controller.seekRelative(
                            const Duration(seconds: -15),
                          ),
                          tooltip: '15 Sekunden zurück',
                          icon: const Icon(Icons.replay_10),
                        ),
                        IconButton.filled(
                          onPressed: controller.loading
                              ? null
                              : controller.playOrPause,
                          tooltip: controller.playing ? 'Pause' : 'Abspielen',
                          icon: controller.loading
                              ? const SizedBox.square(
                                  dimension: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : Icon(
                                  controller.playing
                                      ? Icons.pause
                                      : Icons.play_arrow,
                                ),
                        ),
                        IconButton(
                          onPressed: () => controller.seekRelative(
                            const Duration(seconds: 30),
                          ),
                          tooltip: '30 Sekunden vor',
                          icon: const Icon(Icons.forward_30),
                        ),
                        IconButton(
                          onPressed: controller.next,
                          tooltip: 'Nächster Track',
                          icon: const Icon(Icons.skip_next),
                        ),
                        const SizedBox(width: 8),
                        Text(_time(controller.position)),
                        Expanded(
                          child: Slider(
                            value: current,
                            max: maximum > 0 ? maximum : 1,
                            onChanged: maximum <= 0
                                ? null
                                : (value) => controller.seek(
                                    Duration(milliseconds: value.round()),
                                  ),
                            onChangeEnd: maximum <= 0
                                ? null
                                : (_) => controller.persist(),
                          ),
                        ),
                        Text(_time(controller.duration)),
                        const SizedBox(width: 8),
                        PlaybackSleepTimerButton(
                          timer: controller.sleepTimer,
                          supportsChapterEnd: controller.chapters.isNotEmpty,
                        ),
                        const SizedBox(width: 8),
                        PopupMenuButton<double>(
                          tooltip: 'Geschwindigkeit',
                          initialValue: controller.rate,
                          onSelected: controller.setRate,
                          itemBuilder: (context) => [
                            for (final rate in const [.75, 1.0, 1.25, 1.5, 2.0])
                              PopupMenuItem(value: rate, child: Text('$rate×')),
                          ],
                          child: Chip(label: Text('${controller.rate}×')),
                        ),
                        if (onExpand != null)
                          IconButton(
                            onPressed: onExpand,
                            tooltip: 'Player vergrößern',
                            icon: const Icon(Icons.open_in_full),
                          ),
                      ],
                    ),
                  ),
                  if (controller.error case final error?)
                    Text(
                      error,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  static Widget _compactButton({
    required VoidCallback onPressed,
    required String tooltip,
    required IconData icon,
  }) => IconButton(
    onPressed: onPressed,
    tooltip: tooltip,
    visualDensity: VisualDensity.compact,
    constraints: const BoxConstraints.tightFor(width: 38, height: 38),
    icon: Icon(icon),
  );

  static String _time(Duration duration) {
    final hours = duration.inHours;
    final minutes = (duration.inMinutes % 60).toString().padLeft(2, '0');
    final seconds = (duration.inSeconds % 60).toString().padLeft(2, '0');
    return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
  }
}

class _EmptyLibrary extends StatelessWidget {
  const _EmptyLibrary({this.searchActive = false});

  final bool searchActive;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Text(
        searchActive
            ? 'Keine Medien passen zu dieser Suche und den aktiven Filtern.'
            : 'Noch keine unterstützten Medien gefunden.\nLege Hörbücher nach Autor/Serie/01 - Titel ab und lies den Ordner neu ein.',
        textAlign: TextAlign.center,
      ),
    ),
  );
}
