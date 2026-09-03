import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:fundus_core/fundus_core.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:path/path.dart' as p;

import '../diagnostics/fundus_diagnostics.dart';
import '../library/comic_book_viewer.dart';
import '../library/collection_rules.dart';
import '../library/comic_page_source.dart';
import '../library/document_file_opener.dart';
import '../library/document_preview.dart';
import '../library/fixed_document_source.dart';
import '../library/fundus_breadcrumbs.dart';
import '../library/epub_reader.dart';
import '../library/publication_reader_settings.dart';
import '../library/reflow_text_reader.dart';
import '../library/reader_progress_conflict.dart';
import '../library/work_detail_view_model.dart';
import '../library/work_detail_facts.dart';
import '../library/work_detail_header.dart';
import '../library/work_detail_sections.dart';
import '../library/media_content_schema.dart';
import '../library/work_content_list.dart';
import '../library/work_annotation_list.dart';
import '../library/video_player_page.dart';
import '../library/zip_archive_browser.dart';
import '../playback/playback_sleep_timer_button.dart';
import '../playback/playback_conflict_settings.dart';
import '../playback/track_jump_confirmation.dart';
import 'annotation_sync_settings.dart';
import 'fundus_remote_client.dart';
import 'fundus_remote_document_cache.dart';
import 'http_comic_page_source.dart';
import 'fundus_peer_server_controller.dart';
import 'fundus_remote_player_controller.dart';
import 'fundus_offline_store.dart';
import 'fundus_peer_discovery.dart';
import 'peer_server_identity_store.dart';
import 'remote_saved_view_store.dart';

enum _RemoteLayout { grid, list }

enum _RemoteGrouping { books, authors, series, narrators }

enum _RemoteLibrarySection { media, collections, playlists }

enum _DocumentTrackSort {
  oldestFirst,
  newestFirst,
  seasonEpisode,
  titleAscending,
}

enum _ChapterSelectionMode { range, individual }

bool _isRemoteVideoWork(FundusRemoteWork work) =>
    VideoWorkKind.isVideo(work.kind);

List<FundusBreadcrumb> _remoteDetailBreadcrumbs(WorkDetailViewModel detail) {
  final summary = detail.summary;
  final mediaType = FundusMediaTypeRegistry.forWork(
    kind: summary.kind,
    contentStyle: summary.contentStyle,
    contentSensitivity: summary.contentSensitivity,
    providerMetadata: summary.providerMetadata,
  );
  return [
    FundusBreadcrumb(
      label: summary.sourceLibraryName ?? 'Bibliothek',
      icon: Icons.home_outlined,
    ),
    FundusBreadcrumb(
      label: mediaType?.pluralLabel ?? 'Medien',
      icon: mediaType == null ? Icons.video_library_outlined : null,
    ),
    FundusBreadcrumb(label: summary.title),
  ];
}

Set<int> chapterSelectionRange({
  required int total,
  required int start,
  required int end,
}) {
  if (total <= 0) return const {};
  final normalizedStart = start.clamp(1, total) - 1;
  final normalizedEnd = end.clamp(1, total) - 1;
  final first = normalizedStart < normalizedEnd
      ? normalizedStart
      : normalizedEnd;
  final last = normalizedStart > normalizedEnd
      ? normalizedStart
      : normalizedEnd;
  return {for (var index = first; index <= last; index++) index};
}

List<({FundusRemoteTrack track, int originalIndex})> _orderedRemoteTracks(
  List<FundusRemoteTrack> tracks,
  _DocumentTrackSort sort,
) {
  final result = [
    for (var index = 0; index < tracks.length; index++)
      (track: tracks[index], originalIndex: index),
  ];
  switch (sort) {
    case _DocumentTrackSort.oldestFirst:
      result.sort(
        (left, right) => left.track.position.compareTo(right.track.position),
      );
    case _DocumentTrackSort.newestFirst:
      result.sort(
        (left, right) => right.track.position.compareTo(left.track.position),
      );
    case _DocumentTrackSort.seasonEpisode:
      result.sort((left, right) {
        final leftEpisode =
            left.track.episode ?? parseVideoEpisode(left.track.title);
        final rightEpisode =
            right.track.episode ?? parseVideoEpisode(right.track.title);
        if (leftEpisode == null && rightEpisode == null) {
          return left.track.position.compareTo(right.track.position);
        }
        if (leftEpisode == null) return 1;
        if (rightEpisode == null) return -1;
        final season = leftEpisode.season.compareTo(rightEpisode.season);
        if (season != 0) return season;
        final episode = leftEpisode.episode.compareTo(rightEpisode.episode);
        if (episode != 0) return episode;
        final end = (leftEpisode.episodeEnd ?? leftEpisode.episode).compareTo(
          rightEpisode.episodeEnd ?? rightEpisode.episode,
        );
        return end != 0
            ? end
            : left.track.position.compareTo(right.track.position);
      });
    case _DocumentTrackSort.titleAscending:
      result.sort(
        (left, right) => left.track.title.toLowerCase().compareTo(
          right.track.title.toLowerCase(),
        ),
      );
  }
  return result;
}

Future<void> showFundusRemoteServers(
  BuildContext context, {
  String? initialServerId,
  String? initialLibraryId,
  FundusPeerServerController? peerServer,
  FundusOfflineStore? offlineStore,
  FundusOfflineWork? initialOfflineWork,
  bool closeAfterInitialOfflineWork = false,
  bool showHhh = false,
}) => Navigator.of(context).push(
  MaterialPageRoute<void>(
    builder: (_) => FundusRemoteServersView(
      initialServerId: initialServerId,
      initialLibraryId: initialLibraryId,
      peerServer: peerServer,
      offlineStore: offlineStore,
      initialOfflineWork: initialOfflineWork,
      closeAfterInitialOfflineWork: closeAfterInitialOfflineWork,
      showHhh: showHhh,
    ),
  ),
);

class FundusRemoteServersView extends StatefulWidget {
  const FundusRemoteServersView({
    super.key,
    this.initialServerId,
    this.initialLibraryId,
    this.peerServer,
    this.offlineStore,
    this.initialOfflineWork,
    this.closeAfterInitialOfflineWork = false,
    this.showHhh = false,
  });

  final String? initialServerId;
  final String? initialLibraryId;
  final FundusPeerServerController? peerServer;
  final FundusOfflineStore? offlineStore;
  final FundusOfflineWork? initialOfflineWork;
  final bool closeAfterInitialOfflineWork;
  final bool showHhh;

  @override
  State<FundusRemoteServersView> createState() =>
      _FundusRemoteServersViewState();
}

class _FundusRemoteServersViewState extends State<FundusRemoteServersView> {
  final _store = FundusRemoteServerStore();
  final _client = const FundusRemoteClient();
  final _savedViewStore = const RemoteSavedViewStore();
  final _documentCache = FundusRemoteDocumentCache();
  final _searchController = SearchController();
  late final FundusOfflineStore _offlineStore;
  final _peerDiscovery = FundusPeerDiscovery();
  List<FundusRemoteServer> _servers = const [];
  FundusRemoteServer? _selectedServer;
  FundusRemoteServer? _heartbeatServer;
  List<FundusRemoteLibrary> _libraries = const [];
  FundusRemoteLibrary? _selectedLibrary;
  String? _offlineLibraryFilter;
  List<FundusRemoteWork> _works = const [];
  List<FundusRemotePlaylist> _playlists = const [];
  List<FundusRemoteCollection> _collections = const [];
  _RemoteLibrarySection _librarySection = _RemoteLibrarySection.media;
  String? _selectedCollectionId;
  LibraryWorkQuery _query = const LibraryWorkQuery(sort: LibraryWorkSort.title);
  List<LibrarySavedView> _savedViews = const [];
  _RemoteLayout _layout = _RemoteLayout.grid;
  _RemoteGrouping _grouping = _RemoteGrouping.books;
  String? _selectedGroup;
  String? _selectedCredit;
  bool _busy = true;
  String? _error;
  FundusRemotePlayerController? _remotePlayer;
  final Set<String> _offlineKeys = {};
  List<FundusOfflineWork> _offlineWorks = const [];
  String? _downloadingKey;
  int _downloadCompleted = 0;
  int _downloadTotal = 0;
  int _downloadReceivedBytes = 0;
  int? _downloadExpectedBytes;
  DateTime? _lastDownloadUiUpdate;
  final Map<String, Future<Uint8List>> _coverRequests = {};
  final Map<String, Future<FundusRemoteServer>> _reconnects = {};
  Future<void> _readerProgressQueue = Future<void>.value();
  late final AppLifecycleListener _lifecycleListener;
  Timer? _connectionHeartbeat;
  bool _serverOnline = false;
  bool _authorizationRequired = false;

  List<FundusRemoteWork> _visibleWorks(Iterable<FundusRemoteWork> works) =>
      widget.showHhh
      ? works.toList(growable: false)
      : works.where((work) => !work.isHhh).toList(growable: false);

  @override
  void initState() {
    super.initState();
    _offlineStore = widget.offlineStore ?? FundusOfflineStore();
    _lifecycleListener = AppLifecycleListener(
      onInactive: () => unawaited(_remotePlayer?.persist()),
      onHide: () => unawaited(_remotePlayer?.persist()),
      onPause: () => unawaited(_remotePlayer?.persist()),
    );
    _connectionHeartbeat = Timer.periodic(
      const Duration(seconds: 15),
      (_) => unawaited(_refreshServerConnection()),
    );
    _load();
  }

  @override
  void dispose() {
    _lifecycleListener.dispose();
    _connectionHeartbeat?.cancel();
    _searchController.dispose();
    _remotePlayer?.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      var servers = await _store.load();
      var offlineWorks = await _offlineStore.listAll();
      offlineWorks = await _resolveOfflineSourceLabels(offlineWorks, servers);
      if (!mounted) return;
      setState(() {
        _servers = servers;
        _offlineWorks = widget.showHhh
            ? offlineWorks
            : offlineWorks
                  .where((work) {
                    final sensitivity = work.contentSensitivity;
                    return sensitivity != 'adult_explicit';
                  })
                  .toList(growable: false);
        _offlineKeys.addAll(
          offlineWorks.map(
            (work) => '${work.serverId}/${work.libraryId}/${work.workId}',
          ),
        );
        _busy = false;
      });
      if (widget.initialOfflineWork case final initial?) {
        final current = offlineWorks
            .where(
              (work) =>
                  work.serverId == initial.serverId &&
                  work.libraryId == initial.libraryId &&
                  work.workId == initial.workId,
            )
            .firstOrNull;
        if (current != null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            unawaited(() async {
              await _showOfflineWork(current);
              if (mounted && widget.closeAfterInitialOfflineWork) {
                Navigator.of(context).pop();
              }
            }());
          });
        }
      }
      servers = await _peerDiscovery.relocate(servers);
      await _store.save(servers);
      if (!mounted) return;
      setState(() => _servers = servers);
      final initialServer = servers
          .where((server) => server.id == widget.initialServerId)
          .firstOrNull;
      if (initialServer != null) {
        await _selectServer(initialServer);
        final initialLibrary = _libraries
            .where((library) => library.id == widget.initialLibraryId)
            .firstOrNull;
        if (initialLibrary != null) await _selectLibrary(initialLibrary);
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = 'Gespeicherte Server konnten nicht geladen werden.';
        _busy = false;
      });
    }
  }

  Future<List<FundusOfflineWork>> _resolveOfflineSourceLabels(
    List<FundusOfflineWork> works,
    List<FundusRemoteServer> servers,
  ) async {
    final references = await _store.loadLibraryReferences();
    final serversById = {for (final server in servers) server.id: server};
    final librariesByKey = {
      for (final library in references)
        '${library.serverId}\u0000${library.libraryId}': library,
    };
    return Future.wait([
      for (final work in works)
        () async {
          final server = serversById[work.serverId];
          final library =
              librariesByKey['${work.serverId}\u0000${work.libraryId}'];
          if (server == null || library == null) return work;
          return await _offlineStore.updateSourceLabels(
                serverId: work.serverId,
                libraryId: work.libraryId,
                workId: work.workId,
                serverName: server.name,
                libraryName: library.name,
              ) ??
              work;
        }(),
    ]);
  }

  Future<void> _pair() async {
    final source = await _readPairingCode();
    if (source == null || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final pin = await _askPin();
      if (pin == null) {
        if (mounted) setState(() => _busy = false);
        return;
      }
      final invitation = FundusPairingInvitation.parse(source).withPin(pin);
      final profile = await _client.pair(
        invitation,
        deviceId: await _store.deviceId(),
        deviceName: await _store.deviceName(),
      );
      final servers = [
        profile,
        ..._servers.where((server) => server.id != profile.id),
      ];
      await _store.save(servers);
      if (!mounted) return;
      setState(() {
        _servers = servers;
        _busy = false;
      });
      await _selectServer(profile);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error is FormatException
            ? error.message
            : 'Verbindung fehlgeschlagen. QR/PIN und Netzwerk prüfen.';
        _busy = false;
      });
    }
  }

  Future<String?> _readPairingCode() {
    if (Platform.isAndroid || Platform.isIOS || Platform.isMacOS) {
      return Navigator.of(context).push<String>(
        MaterialPageRoute<String>(builder: (_) => const _PairingScanner()),
      );
    }
    return _manualPairingCode();
  }

  Future<String?> _manualPairingCode() async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Pairing-Code einfügen'),
        content: TextField(
          controller: controller,
          minLines: 4,
          maxLines: 10,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'Inhalt des Fundus-QR-Codes',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Verbinden'),
          ),
        ],
      ),
    );
    controller.dispose();
    return result;
  }

  Future<String?> _askPin() async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Pairing-PIN'),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          maxLength: 6,
          autofocus: true,
          obscureText: true,
          decoration: const InputDecoration(
            hintText: '6-stellige PIN vom Server',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Bestätigen'),
          ),
        ],
      ),
    );
    controller.dispose();
    return result?.length == 6 ? result : null;
  }

  Future<void> _selectServer(FundusRemoteServer server) async {
    setState(() {
      _busy = true;
      _error = null;
      _selectedServer = server;
      _selectedLibrary = null;
      _selectedCredit = null;
      _offlineLibraryFilter = null;
      _works = const [];
      _playlists = const [];
      _collections = const [];
      _selectedCollectionId = null;
    });
    try {
      final result = await _runWithReconnect(
        server,
        (active) => _client.libraries(active),
        retryNotFound: true,
      );
      final libraries = result.value;
      await _store.rememberLibraries(result.server, libraries);
      if (!mounted) return;
      setState(() {
        _selectedServer = result.server;
        _libraries = libraries;
        _serverOnline = true;
        _authorizationRequired = false;
        _busy = false;
      });
    } on FundusRemoteRequestException catch (error) {
      if (!mounted) return;
      setState(() {
        _authorizationRequired =
            error.statusCode == HttpStatus.unauthorized ||
            error.statusCode == HttpStatus.forbidden;
        _error = _authorizationRequired
            ? 'Server erreichbar, aber die Kopplung ist nicht mehr gültig. '
                  'Bitte das Gerät erneut per QR-Code oder PIN koppeln.'
            : 'Server derzeit nicht erreichbar.';
        _serverOnline = false;
        if (server.id == widget.initialServerId &&
            widget.initialLibraryId != null) {
          _selectedServer = null;
          _offlineLibraryFilter = widget.initialLibraryId;
        }
        _busy = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = 'Server derzeit nicht erreichbar.';
        _serverOnline = false;
        _authorizationRequired = false;
        if (server.id == widget.initialServerId &&
            widget.initialLibraryId != null) {
          _selectedServer = null;
          _offlineLibraryFilter = widget.initialLibraryId;
        }
        _busy = false;
      });
    }
  }

  Future<void> _selectLibrary(FundusRemoteLibrary library) async {
    final server = _selectedServer;
    if (server == null) return;
    setState(() {
      _busy = true;
      _error = null;
      _selectedLibrary = library;
      _query = const LibraryWorkQuery(sort: LibraryWorkSort.title);
      _searchController.clear();
      _librarySection = _RemoteLibrarySection.media;
      _selectedCollectionId = null;
      _selectedGroup = null;
      _selectedCredit = null;
    });
    try {
      final result = await _runWithReconnect(
        server,
        (active) async => (
          works: await _client.works(active, library.id),
          playlists: await _client.playlists(active, library.id),
          collections: await _client.collections(active, library.id),
          views: await _savedViewStore.load(active.id, library.id),
        ),
        retryNotFound: true,
      );
      final activeServer = result.server;
      final works = _visibleWorks(result.value.works);
      final playlists = result.value.playlists;
      final collections = result.value.collections;
      final views = result.value.views;
      final offline = await Future.wait([
        for (final work in works)
          _offlineStore.refreshMetadata(
            serverId: activeServer.id,
            libraryId: library.id,
            work: work,
          ),
      ]);
      if (!mounted) return;
      setState(() {
        _selectedServer = activeServer;
        _works = works;
        _playlists = playlists;
        _collections = collections;
        _selectedCollectionId = null;
        _savedViews = views;
        _offlineKeys
          ..removeWhere(
            (key) => key.startsWith('${activeServer.id}/${library.id}/'),
          )
          ..addAll([
            for (var index = 0; index < works.length; index++)
              if (offline[index] != null)
                _offlineKey(activeServer, library, works[index]),
          ]);
        _offlineWorks = [
          for (final current in _offlineWorks)
            offline
                    .whereType<FundusOfflineWork>()
                    .where(
                      (item) =>
                          item.serverId == current.serverId &&
                          item.libraryId == current.libraryId &&
                          item.workId == current.workId,
                    )
                    .firstOrNull ??
                current,
        ];
        _busy = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = 'Medien konnten nicht geladen werden.';
        _busy = false;
      });
    }
  }

  Future<void> _removeServer(FundusRemoteServer server) async {
    final servers = _servers.where((item) => item.id != server.id).toList();
    await _store.save(servers);
    await _store.forgetServerLibraries(server.id);
    if (!context.mounted) return;
    setState(() {
      _servers = servers;
      if (_selectedServer?.id == server.id) {
        _selectedServer = null;
        _selectedLibrary = null;
        _libraries = const [];
        _works = const [];
        _playlists = const [];
        _collections = const [];
        _selectedCollectionId = null;
      }
    });
  }

  Future<String?> _editName(String title, String current) async {
    final controller = TextEditingController(text: current);
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 80,
          decoration: const InputDecoration(
            labelText: 'Gerätename',
            border: OutlineInputBorder(),
          ),
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
    return result?.trim().isEmpty == true ? null : result;
  }

  Future<void> _renameOwnDevice() async {
    final current = await _store.deviceName();
    if (!mounted) return;
    final name = await _editName('Dieses Gerät benennen', current);
    if (name != null) {
      final peerServer = widget.peerServer;
      if (peerServer != null) {
        await peerServer.setDeviceName(name);
      } else {
        await _store.setDeviceName(name);
        final identityStore =
            await PeerServerIdentityStore.platformDefaultAsync();
        final identity = await identityStore.loadOrCreate();
        await identityStore.saveDeviceName(identity.serverId, name);
      }
    }
  }

  Future<void> _renameServer(FundusRemoteServer server) async {
    final name = await _editName('Server benennen', server.name);
    if (name == null) return;
    final renamed = server.copyWith(name: name);
    final servers = [
      for (final item in _servers) item.id == server.id ? renamed : item,
    ];
    await _store.save(servers);
    if (!mounted) return;
    setState(() {
      _servers = servers;
      if (_selectedServer?.id == server.id) _selectedServer = renamed;
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Fundus-Server'),
      actions: [
        Tooltip(
          message: _serverOnline
              ? 'Mit Server verbunden'
              : _authorizationRequired
              ? 'Server erreichbar – erneut koppeln'
              : 'Keine aktive Serververbindung',
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Icon(
              _serverOnline
                  ? Icons.cloud_done
                  : _authorizationRequired
                  ? Icons.key_off_outlined
                  : Icons.cloud_off_outlined,
              color: _serverOnline
                  ? Colors.green
                  : _authorizationRequired
                  ? Theme.of(context).colorScheme.error
                  : null,
            ),
          ),
        ),
        IconButton(
          onPressed: () =>
              Navigator.of(context).popUntil((route) => route.isFirst),
          tooltip: 'Zur Bibliotheksauswahl',
          icon: const Icon(Icons.home_outlined),
        ),
        IconButton(
          onPressed: _renameOwnDevice,
          tooltip: 'Dieses Gerät benennen',
          icon: const Icon(Icons.badge_outlined),
        ),
        IconButton(
          onPressed: _busy ? null : _manualPairingCodeThenConnect,
          tooltip: 'Code einfügen',
          icon: const Icon(Icons.content_paste),
        ),
        IconButton(
          onPressed: _busy ? null : _pair,
          tooltip: 'QR-Code scannen',
          icon: const Icon(Icons.qr_code_scanner),
        ),
      ],
    ),
    body: Column(
      children: [
        if (_busy) const LinearProgressIndicator(),
        if (_downloadingKey != null) ...[
          LinearProgressIndicator(value: _downloadProgress),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Text(_downloadLabel),
          ),
        ],
        if (_error case final error?)
          MaterialBanner(
            content: Text(error),
            actions: [
              TextButton(
                onPressed: () => setState(() => _error = null),
                child: const Text('OK'),
              ),
            ],
          ),
        Expanded(child: _content()),
      ],
    ),
    floatingActionButton: _servers.isEmpty
        ? FloatingActionButton.extended(
            onPressed: _busy ? null : _pair,
            icon: const Icon(Icons.qr_code_scanner),
            label: const Text('Server verbinden'),
          )
        : null,
    bottomNavigationBar: _remotePlayer == null
        ? null
        : _RemotePlayerBar(
            controller: _remotePlayer!,
            onExpand: _openExpandedPlayer,
          ),
  );

  void _openExpandedPlayer() {
    final player = _remotePlayer;
    if (player == null) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _RemoteExpandedPlayer(controller: player),
      ),
    );
  }

  Future<void> _manualPairingCodeThenConnect() async {
    final source = await _manualPairingCode();
    if (source == null || !mounted) return;
    await _pairFromSource(source);
  }

  Future<void> _pairFromSource(String source) async {
    setState(() => _busy = true);
    try {
      final pin = await _askPin();
      if (pin == null) {
        if (mounted) setState(() => _busy = false);
        return;
      }
      final profile = await _client.pair(
        FundusPairingInvitation.parse(source).withPin(pin),
        deviceId: await _store.deviceId(),
        deviceName: await _store.deviceName(),
      );
      final servers = [
        profile,
        ..._servers.where((server) => server.id != profile.id),
      ];
      await _store.save(servers);
      if (!mounted) return;
      setState(() {
        _servers = servers;
        _busy = false;
      });
      await _selectServer(profile);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Pairing-Code ungültig oder Server nicht erreichbar.';
      });
    }
  }

  Widget _content() {
    if (_offlineLibraryFilter != null) return _offlineLibraryView();
    final selectedLibrary = _selectedLibrary;
    if (selectedLibrary != null) return _worksGrid(selectedLibrary);
    final selectedServer = _selectedServer;
    if (selectedServer != null) return _libraryList(selectedServer);
    return _serverList();
  }

  Widget _offlineLibraryView() {
    final source = _offlineWorks
        .where((work) => work.libraryId == _offlineLibraryFilter)
        .toList();
    final byId = {for (final work in source) work.workId: work};
    final summaries = [for (final work in source) _offlineSummary(work)];
    final works = LibraryWorkSearch.apply(
      summaries,
      _query,
    ).map((summary) => byId[summary.id]!).toList(growable: false);
    final kinds = source.map((work) => work.kind).toSet().toList()..sort();
    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: ListTile(
            leading: BackButton(
              onPressed: () => setState(() => _offlineLibraryFilter = null),
            ),
            title: const Text('Offline-Medien'),
            subtitle: Text('${works.length} Medium/Medien auf diesem Gerät'),
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: SearchBar(
              controller: _searchController,
              leading: const Icon(Icons.search),
              hintText: 'Titel, Person oder Serie …',
              onChanged: (value) =>
                  setState(() => _query = _query.copyWith(text: value)),
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                SegmentedButton<_RemoteLayout>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(
                      value: _RemoteLayout.grid,
                      icon: Icon(Icons.grid_view),
                    ),
                    ButtonSegment(
                      value: _RemoteLayout.list,
                      icon: Icon(Icons.view_list),
                    ),
                  ],
                  selected: {_layout},
                  onSelectionChanged: (value) =>
                      setState(() => _layout = value.first),
                ),
                const SizedBox(width: 8),
                for (final kind in kinds) ...[
                  ChoiceChip(
                    label: Text(_kindLabel(kind)),
                    selected: _query.kinds.contains(kind),
                    onSelected: (_) => setState(
                      () => _query = _query.copyWith(
                        kinds: _query.kinds.contains(kind) ? {} : {kind},
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
              ],
            ),
          ),
        ),
        if (_layout == _RemoteLayout.grid)
          SliverPadding(
            padding: const EdgeInsets.all(16),
            sliver: SliverGrid.builder(
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 220,
                mainAxisExtent: 310,
                crossAxisSpacing: 12,
                mainAxisSpacing: 12,
              ),
              itemCount: works.length,
              itemBuilder: (context, index) => _offlineWorkCard(works[index]),
            ),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.all(16),
            sliver: SliverList.builder(
              itemCount: works.length,
              itemBuilder: (context, index) {
                final offline = works[index];
                return Card(
                  child: ListTile(
                    leading: SizedBox(
                      width: 48,
                      height: 58,
                      child: _offlineCover(offline),
                    ),
                    title: Text(offline.title),
                    subtitle: Text(_offlineSubtitle(offline)),
                    trailing: offline.incomplete
                        ? const Tooltip(
                            message: 'Download unvollständig',
                            child: Icon(Icons.warning_amber_rounded),
                          )
                        : const Icon(Icons.chevron_right),
                    onTap: () => _showOfflineWork(offline),
                  ),
                );
              },
            ),
          ),
      ],
    );
  }

  Widget _offlineWorkCard(FundusOfflineWork offline) => Card(
    clipBehavior: Clip.antiAlias,
    child: InkWell(
      onTap: () => _showOfflineWork(offline),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: _offlineCover(offline)),
          Padding(
            padding: const EdgeInsets.all(10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  offline.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                Text(
                  offline.authors.join(', '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  _kindLabel(offline.kind),
                  style: Theme.of(context).textTheme.labelSmall,
                ),
                Row(
                  children: [
                    Icon(
                      offline.incomplete
                          ? Icons.warning_amber_rounded
                          : Icons.download_done,
                      size: 15,
                    ),
                    const SizedBox(width: 4),
                    Text(offline.incomplete ? 'Unvollständig' : 'Offline'),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );

  Widget _offlineCover(FundusOfflineWork offline) => offline.coverPath == null
      ? Icon(_kindIcon(offline.kind), size: 72)
      : Image.file(
          File(offline.coverPath!),
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => Icon(_kindIcon(offline.kind), size: 72),
        );

  LibraryWorkSummary _offlineSummary(FundusOfflineWork work) =>
      WorkDetailViewModel.fromOffline(work).summary;

  Widget _serverList() => ListView(
    padding: const EdgeInsets.all(16),
    children: [
      if (_servers.isEmpty)
        const Padding(
          padding: EdgeInsets.all(32),
          child: Center(child: Text('Noch kein Fundus-Server verbunden.')),
        ),
      for (final server in _servers)
        Card(
          child: ListTile(
            leading: const Icon(Icons.dns_outlined),
            title: Text(server.name),
            subtitle: Text(server.baseUri.host),
            onTap: () => _selectServer(server),
            trailing: Wrap(
              children: [
                IconButton(
                  onPressed: () => _renameServer(server),
                  tooltip: 'Server benennen',
                  icon: const Icon(Icons.edit_outlined),
                ),
                IconButton(
                  onPressed: () => _removeServer(server),
                  tooltip: 'Von diesem Gerät entfernen',
                  icon: const Icon(Icons.delete_outline),
                ),
              ],
            ),
          ),
        ),
      if (_offlineWorks.isNotEmpty) ...[
        const Padding(
          padding: EdgeInsets.fromLTRB(4, 20, 4, 8),
          child: Text(
            'Offline verfügbar',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
        ),
        for (final offline in _offlineWorks)
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
              subtitle: Text(_offlineSubtitle(offline)),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _showOfflineWork(offline),
            ),
          ),
      ],
    ],
  );

  Widget _libraryList(FundusRemoteServer server) => ListView(
    padding: const EdgeInsets.all(16),
    children: [
      ListTile(
        leading: BackButton(
          onPressed: () => setState(() {
            _selectedServer = null;
            _libraries = const [];
          }),
        ),
        title: Text(server.name),
        subtitle: const Text('Freigegebene Bibliotheken'),
      ),
      for (final library in _libraries)
        Card(
          child: ListTile(
            leading: const Icon(Icons.video_library_outlined),
            title: Text(library.name),
            subtitle: Text('${library.workCount} Medien'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _selectLibrary(library),
          ),
        ),
    ],
  );

  Widget _worksGrid(FundusRemoteLibrary library) {
    if (_librarySection == _RemoteLibrarySection.playlists) {
      return _remotePlaylistsView(library);
    }
    if (_librarySection == _RemoteLibrarySection.collections) {
      return _remoteCollectionsView(library);
    }
    final server = _selectedServer!;
    final kinds = _works.map((work) => work.kind).toSet().toList()..sort();
    final byId = {for (final work in _works) work.id: work};
    var works = LibraryWorkSearch.apply(
      _works.map(_remoteSummary),
      _query,
    ).map((work) => byId[work.id]!).toList();
    if (_selectedCollectionId case final collectionId?) {
      final collection = _collections
          .where((item) => item.id == collectionId)
          .firstOrNull;
      if (collection != null) {
        final summaries = {
          for (final work in _works) work.id: _remoteSummary(work),
        };
        works = works
            .where(
              (work) => collection.isSmart
                  ? summaries[work.id] != null &&
                        matchesCollectionRules(
                          summaries[work.id]!,
                          collection.rules,
                        )
                  : collection.workIds.contains(work.id),
            )
            .toList();
      }
    }
    if (_selectedGroup case final group?) {
      works = works
          .where((work) => _remoteGroupValues(work).contains(group))
          .toList();
    }
    if (_selectedCredit case final credit?) {
      final needle = credit.toLowerCase();
      works = works
          .where(
            (work) => _remoteVideoCredits(
              work.providerMetadata,
            ).any((item) => item.name.toLowerCase() == needle),
          )
          .toList();
    }
    final groups = _remoteGroups(works);
    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: ListTile(
            leading: BackButton(
              onPressed: () => setState(() {
                if (_selectedGroup != null) {
                  _selectedGroup = null;
                } else if (_selectedCollectionId != null) {
                  _selectedCollectionId = null;
                } else {
                  _selectedLibrary = null;
                }
              }),
            ),
            title: Text(_selectedGroup ?? library.name),
            subtitle: Text('${works.length} Medien'),
          ),
        ),
        SliverToBoxAdapter(child: _librarySectionSelector()),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: SearchBar(
              controller: _searchController,
              leading: const Icon(Icons.search),
              hintText: 'Titel, Person oder Serie …',
              onChanged: (value) =>
                  setState(() => _query = _query.copyWith(text: value)),
            ),
          ),
        ),
        if (_selectedCredit case final credit?)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: InputChip(
                  avatar: const Icon(Icons.person_outline, size: 18),
                  label: Text('Besetzung: $credit'),
                  onDeleted: () => setState(() => _selectedCredit = null),
                ),
              ),
            ),
          ),
        SliverToBoxAdapter(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                SegmentedButton<_RemoteLayout>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(
                      value: _RemoteLayout.grid,
                      icon: Icon(Icons.grid_view),
                    ),
                    ButtonSegment(
                      value: _RemoteLayout.list,
                      icon: Icon(Icons.view_list),
                    ),
                  ],
                  selected: {_layout},
                  onSelectionChanged: (value) =>
                      setState(() => _layout = value.first),
                ),
                const SizedBox(width: 8),
                IconButton.filledTonal(
                  onPressed: _showRemoteFilters,
                  tooltip: 'Filter kombinieren',
                  icon: Badge(
                    isLabelVisible: _query.hasFilters,
                    child: const Icon(Icons.filter_list),
                  ),
                ),
                IconButton(
                  onPressed: () => setState(() {
                    final tags = {..._query.tags};
                    tags.contains('Favorit')
                        ? tags.remove('Favorit')
                        : tags.add('Favorit');
                    _query = _query.copyWith(tags: tags);
                  }),
                  tooltip: _query.tags.contains('Favorit')
                      ? 'Alle Titel anzeigen'
                      : 'Nur Favoriten',
                  icon: Icon(
                    _query.tags.contains('Favorit')
                        ? Icons.star
                        : Icons.star_border,
                  ),
                ),
                const SizedBox(width: 8),
                MenuAnchor(
                  builder: (context, controller, child) => IconButton(
                    onPressed: controller.isOpen
                        ? controller.close
                        : controller.open,
                    tooltip: 'Gespeicherte Ansichten',
                    icon: const Icon(Icons.bookmarks_outlined),
                  ),
                  menuChildren: [
                    MenuItemButton(
                      onPressed: _saveRemoteView,
                      leadingIcon: const Icon(Icons.bookmark_add_outlined),
                      child: const Text('Aktuelle Ansicht speichern'),
                    ),
                    for (final view in _savedViews)
                      MenuItemButton(
                        onPressed: () => _applyRemoteView(view),
                        leadingIcon: const Icon(Icons.bookmark_outline),
                        child: Text(view.name),
                      ),
                    if (_savedViews.isNotEmpty)
                      MenuItemButton(
                        onPressed: _manageRemoteViews,
                        leadingIcon: const Icon(Icons.edit_outlined),
                        child: const Text('Ansichten verwalten'),
                      ),
                  ],
                ),
                const SizedBox(width: 8),
                DropdownButton<_RemoteGrouping>(
                  value: _grouping,
                  onChanged: (value) => setState(() {
                    _grouping = value!;
                    _selectedGroup = null;
                  }),
                  items: const [
                    DropdownMenuItem(
                      value: _RemoteGrouping.books,
                      child: Text('Bücher'),
                    ),
                    DropdownMenuItem(
                      value: _RemoteGrouping.authors,
                      child: Text('Autoren'),
                    ),
                    DropdownMenuItem(
                      value: _RemoteGrouping.series,
                      child: Text('Serien'),
                    ),
                    DropdownMenuItem(
                      value: _RemoteGrouping.narrators,
                      child: Text('Sprecher'),
                    ),
                  ],
                ),
                const SizedBox(width: 8),
                DropdownButton<LibraryWorkSort>(
                  value: _query.sort,
                  onChanged: (value) =>
                      setState(() => _query = _query.copyWith(sort: value!)),
                  items: const [
                    DropdownMenuItem(
                      value: LibraryWorkSort.title,
                      child: Text('Titel A–Z'),
                    ),
                    DropdownMenuItem(
                      value: LibraryWorkSort.author,
                      child: Text('Autor A–Z'),
                    ),
                    DropdownMenuItem(
                      value: LibraryWorkSort.series,
                      child: Text('Serie'),
                    ),
                    DropdownMenuItem(
                      value: LibraryWorkSort.recentlyAdded,
                      child: Text('Zuletzt hinzugefügt'),
                    ),
                    DropdownMenuItem(
                      value: LibraryWorkSort.recentlyListened,
                      child: Text('Zuletzt gehört'),
                    ),
                    DropdownMenuItem(
                      value: LibraryWorkSort.progress,
                      child: Text('Fortschritt'),
                    ),
                    DropdownMenuItem(
                      value: LibraryWorkSort.duration,
                      child: Text('Dauer'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        if (kinds.length > 1)
          SliverToBoxAdapter(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  ChoiceChip(
                    label: const Text('Alle'),
                    selected: _query.kinds.isEmpty,
                    onSelected: (_) =>
                        setState(() => _query = _query.copyWith(kinds: {})),
                  ),
                  const SizedBox(width: 8),
                  for (final kind in kinds) ...[
                    ChoiceChip(
                      label: Text(_kindLabel(kind)),
                      selected: _query.kinds.contains(kind),
                      onSelected: (_) => setState(
                        () => _query = _query.copyWith(kinds: {kind}),
                      ),
                    ),
                    const SizedBox(width: 8),
                  ],
                ],
              ),
            ),
          ),
        if (_grouping != _RemoteGrouping.books && _selectedGroup == null)
          SliverPadding(
            padding: const EdgeInsets.all(16),
            sliver: SliverList.builder(
              itemCount: groups.length,
              itemBuilder: (context, index) {
                final group = groups[index];
                return Card(
                  child: ListTile(
                    leading: Icon(
                      _grouping == _RemoteGrouping.series
                          ? Icons.account_tree_outlined
                          : Icons.person_outline,
                    ),
                    title: Text(group.$1),
                    subtitle: Text('${group.$2} Medium/Medien'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => setState(() => _selectedGroup = group.$1),
                  ),
                );
              },
            ),
          )
        else if (_layout == _RemoteLayout.grid)
          SliverPadding(
            padding: const EdgeInsets.all(16),
            sliver: SliverGrid.builder(
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 220,
                mainAxisExtent: 310,
                crossAxisSpacing: 12,
                mainAxisSpacing: 12,
              ),
              itemCount: works.length,
              itemBuilder: (context, index) {
                final work = works[index];
                return Card(
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: () => _showWork(server, library, work),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(
                          child: work.hasCover
                              ? _remoteCover(server, library, work)
                              : Icon(_kindIcon(work.kind), size: 72),
                        ),
                        Padding(
                          padding: const EdgeInsets.all(10),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                work.title,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              Text(
                                work.authors.join(', '),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              Text(
                                _kindLabel(work.kind),
                                style: Theme.of(context).textTheme.labelSmall,
                              ),
                              Row(
                                children: [
                                  Icon(
                                    _offlineKeys.contains(
                                          _offlineKey(server, library, work),
                                        )
                                        ? Icons.download_done
                                        : Icons.cloud_outlined,
                                    size: 15,
                                  ),
                                  const SizedBox(width: 4),
                                  Text(
                                    _offlineKeys.contains(
                                          _offlineKey(server, library, work),
                                        )
                                        ? 'Offline verfügbar'
                                        : 'Server',
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.all(16),
            sliver: SliverList.builder(
              itemCount: works.length,
              itemBuilder: (context, index) {
                final work = works[index];
                return Card(
                  child: ListTile(
                    leading: SizedBox(
                      width: 48,
                      height: 58,
                      child: work.hasCover
                          ? _remoteCover(server, library, work)
                          : Icon(_kindIcon(work.kind)),
                    ),
                    title: Text(work.title),
                    subtitle: Text(
                      [
                        ...work.authors,
                        if (work.series != null) work.series!,
                      ].join(' · '),
                    ),
                    trailing: Icon(
                      _offlineKeys.contains(_offlineKey(server, library, work))
                          ? Icons.download_done
                          : Icons.cloud_outlined,
                    ),
                    onTap: () => _showWork(server, library, work),
                  ),
                );
              },
            ),
          ),
      ],
    );
  }

  Widget _librarySectionSelector() => Padding(
    padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
    child: SegmentedButton<_RemoteLibrarySection>(
      segments: const [
        ButtonSegment(
          value: _RemoteLibrarySection.media,
          icon: Icon(Icons.video_library_outlined),
          label: Text('Medien'),
        ),
        ButtonSegment(
          value: _RemoteLibrarySection.collections,
          icon: Icon(Icons.collections_bookmark_outlined),
          label: Text('Sammlungen'),
        ),
        ButtonSegment(
          value: _RemoteLibrarySection.playlists,
          icon: Icon(Icons.playlist_play),
          label: Text('Playlisten'),
        ),
      ],
      selected: {_librarySection},
      onSelectionChanged: (value) =>
          setState(() => _librarySection = value.first),
    ),
  );

  Widget _remoteCollectionsView(FundusRemoteLibrary library) {
    final server = _selectedServer;
    final visibleWorkIds = _works.map((work) => work.id).toSet();
    final collections = _collections
        .where(
          (collection) =>
              collection.isSmart ||
              collection.workIds.isEmpty ||
              collection.workIds.any(visibleWorkIds.contains),
        )
        .toList(growable: false);
    return ListView(
      padding: const EdgeInsets.only(bottom: 16),
      children: [
        ListTile(
          leading: BackButton(
            onPressed: () => setState(() {
              _selectedLibrary = null;
              _selectedGroup = null;
              _selectedCredit = null;
              _selectedCollectionId = null;
            }),
          ),
          title: Text(library.name),
          subtitle: Text('${collections.length} Sammlung(en)'),
          trailing: IconButton(
            tooltip: 'Neue Sammlung',
            icon: const Icon(Icons.create_new_folder_outlined),
            onPressed: server == null
                ? null
                : () => _editRemoteCollection(library),
          ),
        ),
        _librarySectionSelector(),
        if (collections.isEmpty)
          const Padding(
            padding: EdgeInsets.all(32),
            child: Center(
              child: Text(
                'Auf diesem Server wurden noch keine Sammlungen gespeichert.',
                textAlign: TextAlign.center,
              ),
            ),
          ),
        for (final collection in collections)
          Card(
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
            child: ListTile(
              leading: Icon(
                collection.isSmart
                    ? Icons.auto_awesome_outlined
                    : Icons.collections_bookmark_outlined,
              ),
              title: Text(collection.name),
              subtitle: Text(
                collection.isSmart
                    ? 'Smart-Sammlung'
                    : '${collection.workIds.where(visibleWorkIds.contains).length} Werk(e)',
              ),
              trailing: Wrap(
                spacing: 2,
                children: [
                  IconButton(
                    tooltip: 'Sammlung bearbeiten',
                    icon: const Icon(Icons.edit_outlined),
                    onPressed: server == null
                        ? null
                        : () => _editRemoteCollection(
                            library,
                            collection: collection,
                          ),
                  ),
                  IconButton(
                    tooltip: 'Sammlung löschen',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: server == null
                        ? null
                        : () => _deleteRemoteCollection(library, collection),
                  ),
                  IconButton(
                    tooltip: 'Sammlung öffnen',
                    icon: const Icon(Icons.chevron_right),
                    onPressed: () => setState(() {
                      _librarySection = _RemoteLibrarySection.media;
                      _selectedCollectionId = collection.id;
                      _selectedGroup = null;
                      _selectedCredit = null;
                    }),
                  ),
                ],
              ),
              onTap: () => setState(() {
                _librarySection = _RemoteLibrarySection.media;
                _selectedCollectionId = collection.id;
                _selectedGroup = null;
                _selectedCredit = null;
              }),
            ),
          ),
      ],
    );
  }

  Future<void> _editRemoteCollection(
    FundusRemoteLibrary library, {
    FundusRemoteCollection? collection,
  }) async {
    final server = _selectedServer;
    if (server == null || !mounted) return;
    final controller = TextEditingController(text: collection?.name ?? '');
    final selected = {...?collection?.workIds};
    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(
            collection == null
                ? 'Neue Sammlung'
                : 'Sammlung „${collection.name}“ bearbeiten',
          ),
          content: SizedBox(
            width: 620,
            height: 520,
            child: Column(
              children: [
                TextField(
                  controller: controller,
                  autofocus: collection == null,
                  maxLength: 200,
                  decoration: const InputDecoration(
                    labelText: 'Name',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    collection?.isSmart == true
                        ? 'Smart-Sammlungen werden über ihre Regeln gesteuert.'
                        : 'Werke in der Sammlung',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                const SizedBox(height: 6),
                Expanded(
                  child: collection?.isSmart == true
                      ? const Center(
                          child: Text('Die Regeln bleiben unverändert.'),
                        )
                      : ListView.builder(
                          itemCount: _works.length,
                          itemBuilder: (context, index) {
                            final work = _works[index];
                            return CheckboxListTile(
                              dense: true,
                              value: selected.contains(work.id),
                              title: Text(work.title),
                              subtitle: Text(work.kind),
                              onChanged: (value) => setDialogState(() {
                                if (value == true) {
                                  selected.add(work.id);
                                } else {
                                  selected.remove(work.id);
                                }
                              }),
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Abbrechen'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: Text(collection == null ? 'Anlegen' : 'Speichern'),
            ),
          ],
        ),
      ),
    );
    final name = controller.text.trim();
    controller.dispose();
    if (result != true || name.isEmpty || !mounted) return;
    try {
      final saved = collection == null
          ? await _runWithReconnect(
              server,
              (active) => _client.createCollection(
                active,
                libraryId: library.id,
                name: name,
                workIds: selected.toList(),
              ),
            )
          : await _runWithReconnect(
              server,
              (active) => _client.saveCollection(
                active,
                libraryId: library.id,
                collection: collection,
                name: name,
                kind: collection.kind,
                rules: collection.rules,
                parentId: collection.parentId,
                workIds: collection.isSmart
                    ? collection.workIds
                    : selected.toList(),
              ),
            );
      if (!mounted) return;
      setState(() {
        _selectedServer = saved.server;
        _collections = [
          ..._collections.where((item) => item.id != saved.value.id),
          saved.value,
        ];
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            collection == null ? 'Sammlung angelegt.' : 'Sammlung gespeichert.',
          ),
        ),
      );
    } on FundusRemoteCollectionConflict catch (error) {
      if (!mounted) return;
      setState(() {
        _collections = [
          ..._collections.where((item) => item.id != error.current.id),
          error.current,
        ];
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Die Sammlung wurde auf einem anderen Gerät geändert. Sie wurde neu geladen.',
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Sammlung konnte nicht gespeichert werden: $error'),
        ),
      );
    }
  }

  Future<void> _deleteRemoteCollection(
    FundusRemoteLibrary library,
    FundusRemoteCollection collection,
  ) async {
    final server = _selectedServer;
    if (server == null || !mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Sammlung löschen?'),
        content: Text('„${collection.name}“ wird auf dem Server gelöscht.'),
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
    try {
      final result = await _runWithReconnect(
        server,
        (active) => _client.deleteCollection(
          active,
          libraryId: library.id,
          collection: collection,
        ),
      );
      if (!mounted) return;
      setState(() {
        _selectedServer = result.server;
        _collections = _collections
            .where((item) => item.id != collection.id)
            .toList(growable: false);
        if (_selectedCollectionId == collection.id) {
          _selectedCollectionId = null;
        }
      });
    } on FundusRemoteCollectionConflict catch (error) {
      if (!mounted) return;
      setState(() {
        _collections = [
          ..._collections.where((item) => item.id != error.current.id),
          error.current,
        ];
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Die Sammlung wurde auf einem anderen Gerät geändert. Sie wurde neu geladen.',
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Sammlung konnte nicht gelöscht werden: $error'),
        ),
      );
    }
  }

  Widget _remotePlaylistsView(FundusRemoteLibrary library) {
    final server = _selectedServer!;
    final visibleWorkIds = _works.map((work) => work.id).toSet();
    final playlists = _playlists
        .where(
          (playlist) =>
              widget.showHhh || playlist.workIds.every(visibleWorkIds.contains),
        )
        .toList(growable: false);
    return ListView(
      padding: const EdgeInsets.only(bottom: 16),
      children: [
        ListTile(
          leading: BackButton(
            onPressed: () => setState(() {
              _selectedLibrary = null;
              _selectedGroup = null;
              _selectedCredit = null;
            }),
          ),
          title: Text(library.name),
          subtitle: Text('${playlists.length} Playlist(en)'),
        ),
        _librarySectionSelector(),
        if (playlists.isEmpty)
          const Padding(
            padding: EdgeInsets.all(32),
            child: Center(
              child: Text(
                'Auf diesem Server wurden noch keine Playlists gespeichert.',
                textAlign: TextAlign.center,
              ),
            ),
          ),
        for (final playlist in playlists)
          Card(
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
            child: ListTile(
              leading: const Icon(Icons.queue_music),
              title: Text(playlist.name),
              subtitle: Text(
                [
                  if (playlist.mediaType != null)
                    _kindLabel(playlist.mediaType!),
                  '${playlist.workIds.length} Werk(e)',
                  'Revision ${playlist.revision}',
                ].join(' · '),
              ),
              trailing: IconButton.filledTonal(
                onPressed: playlist.workIds.isEmpty
                    ? null
                    : () => _playRemotePlaylist(server, library, playlist),
                tooltip: 'Playlist abspielen',
                icon: const Icon(Icons.play_arrow),
              ),
              onTap: playlist.workIds.isEmpty
                  ? null
                  : () => _playRemotePlaylist(server, library, playlist),
            ),
          ),
      ],
    );
  }

  Future<void> _playRemotePlaylist(
    FundusRemoteServer server,
    FundusRemoteLibrary library,
    FundusRemotePlaylist playlist,
  ) async {
    final byId = {for (final work in _works) work.id: work};
    final works = playlist.workIds
        .map((id) => byId[id])
        .whereType<FundusRemoteWork>()
        .toList(growable: false);
    if (works.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Diese Playlist enthält keine verfügbaren Medien.'),
        ),
      );
      return;
    }
    final player =
        _remotePlayer ??
        FundusRemotePlayerController(
          deviceId: await _store.deviceId(),
          deviceName: await _store.deviceName(),
          offlineStore: _offlineStore,
          onConflict: (conflict) => resolvePlaybackConflict(context, conflict),
          serverResolver: _relocatePlayerServer,
        );
    if (_remotePlayer == null && mounted) {
      setState(() => _remotePlayer = player);
    }
    await player.openQueue(server, library, works, playlist: playlist);
    if (!mounted) return;
    final missing = playlist.workIds.length - works.length;
    if (missing > 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('$missing nicht verfügbare Werk(e) übersprungen.'),
        ),
      );
    }
  }

  Future<void> _playRemoteVideo(
    FundusRemoteServer server,
    FundusRemoteLibrary library,
    FundusRemoteWork work, {
    FundusOfflineWork? offlineWork,
    String? startFileId,
    Duration? startPosition,
  }) async {
    final player =
        _remotePlayer ??
        FundusRemotePlayerController(
          deviceId: await _store.deviceId(),
          deviceName: await _store.deviceName(),
          offlineStore: _offlineStore,
          onConflict: (conflict) => resolvePlaybackConflict(context, conflict),
          serverResolver: _relocatePlayerServer,
        );
    if (_remotePlayer == null && mounted) {
      setState(() => _remotePlayer = player);
    }
    if (offlineWork != null) {
      await player.open(
        server,
        library,
        work,
        offlineWork: offlineWork,
        startFileId: startFileId,
        startPosition: startPosition,
        // Let the fullscreen route attach the native video surface before
        // starting a resumed stream. Starting beforehand can leave audio
        // running with a black/stale video texture.
        autoPlay: false,
      );
    } else {
      final result = await _runWithReconnect(
        server,
        (active) => _client.verifyEndpoint(active, active.baseUri),
      );
      await player.open(
        result.server,
        library,
        work,
        startFileId: startFileId,
        startPosition: startPosition,
        autoPlay: false,
      );
    }
    if (mounted) {
      // The controller was opened paused so the route can attach its native
      // video surface before playback begins. Capture the restored position;
      // the shared route performs the final seek/prime sequence.
      final initialPosition = player.position;
      await showFundusVideoPlayerForPlayer(
        context,
        player: player.player,
        videoController: player.videoController,
        title: work.title,
        initialPosition: initialPosition,
        onAudioTrackSelected: player.rememberVideoAudioTrack,
        onSubtitleTrackSelected: player.rememberVideoSubtitleTrack,
        onBookmarkAtCurrent: player.addBookmarkAtCurrent,
      );
    }
  }

  LibraryWorkSummary _remoteSummary(FundusRemoteWork work) {
    final server = _selectedServer;
    final library = _selectedLibrary;
    final offline =
        server != null &&
        library != null &&
        _offlineKeys.contains(_offlineKey(server, library, work));
    return WorkDetailViewModel.fromRemote(
      work,
      serverId: server?.id ?? 'remote',
      libraryId: library?.id ?? 'remote',
      serverName: server?.name,
      libraryName: library?.name,
      offlineAvailable: offline,
    ).summary;
  }

  Future<void> _showRemoteFilters() async {
    var progress = _query.progress;
    var offlineOnly = _query.offlineOnly;
    var languages = {..._query.languages};
    var authors = {..._query.authors};
    var narrators = {..._query.narrators};
    var series = {..._query.series};
    var tags = {..._query.tags};
    final result = await showDialog<LibraryWorkQuery>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          Set<String> values(Iterable<String?> source) => source
              .whereType<String>()
              .map((value) => value.trim())
              .where((value) => value.isNotEmpty)
              .toSet();
          Widget choices(
            String title,
            Set<String> available,
            Set<String> selected,
          ) {
            final sorted = available.toList()
              ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
            if (sorted.isEmpty) return const SizedBox.shrink();
            return Padding(
              padding: const EdgeInsets.only(top: 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    children: [
                      for (final value in sorted)
                        FilterChip(
                          label: Text(value),
                          selected: selected.contains(value),
                          onSelected: (_) => setDialogState(() {
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
            title: const Text('Netzwerkbibliothek filtern'),
            content: SizedBox(
              width: 620,
              child: SingleChildScrollView(
                child: Column(
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
                      onChanged: (value) =>
                          setDialogState(() => progress = value!),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Nur heruntergeladene Medien'),
                      value: offlineOnly,
                      onChanged: (value) =>
                          setDialogState(() => offlineOnly = value),
                    ),
                    choices(
                      'Sprache',
                      values(_works.map((work) => work.language)),
                      languages,
                    ),
                    choices(
                      'Autor',
                      values(_works.expand((work) => work.authors)),
                      authors,
                    ),
                    choices(
                      'Sprecher',
                      values(_works.expand((work) => work.narrators)),
                      narrators,
                    ),
                    choices(
                      'Serie',
                      values(_works.map((work) => work.series)),
                      series,
                    ),
                    choices(
                      'Tags',
                      values(_works.expand((work) => work.tags)),
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
                  _query.copyWith(
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
              FilledButton(
                onPressed: () => Navigator.pop(
                  context,
                  _query.copyWith(
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
    if (result != null && mounted) setState(() => _query = result);
  }

  Future<void> _saveRemoteView() async {
    final server = _selectedServer;
    final library = _selectedLibrary;
    if (server == null || library == null) return;
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Ansicht speichern'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Name'),
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
    final views = await _savedViewStore.save(
      server.id,
      library.id,
      name,
      _query,
    );
    if (mounted) setState(() => _savedViews = views);
  }

  void _applyRemoteView(LibrarySavedView view) => setState(() {
    _query = view.query;
    _searchController.text = view.query.text;
    _selectedGroup = null;
    _selectedCredit = null;
  });

  Future<void> _manageRemoteViews() async {
    final server = _selectedServer;
    final library = _selectedLibrary;
    if (server == null || library == null) return;
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
                    trailing: IconButton(
                      tooltip: 'Ansicht löschen',
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () async {
                        final views = await _savedViewStore.delete(
                          server.id,
                          library.id,
                          view.id,
                        );
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

  List<String> _remoteGroupValues(FundusRemoteWork work) => switch (_grouping) {
    _RemoteGrouping.books => const [],
    _RemoteGrouping.authors => work.authors,
    _RemoteGrouping.series => [if (work.series != null) work.series!],
    _RemoteGrouping.narrators => work.narrators,
  };

  List<(String, int)> _remoteGroups(List<FundusRemoteWork> works) {
    final counts = <String, int>{};
    for (final work in works) {
      for (final value in _remoteGroupValues(work)) {
        counts.update(value, (count) => count + 1, ifAbsent: () => 1);
      }
    }
    return counts.entries.map((entry) => (entry.key, entry.value)).toList()
      ..sort(
        (left, right) =>
            left.$1.toLowerCase().compareTo(right.$1.toLowerCase()),
      );
  }

  static bool _samePosition(MediaPosition left, MediaPosition right) =>
      left.kind == right.kind &&
      left.fileId == right.fileId &&
      left.chapterId == right.chapterId &&
      left.elementId == right.elementId &&
      left.numericValue == right.numericValue &&
      left.scrollOffset == right.scrollOffset;

  static bool _sameBookmark(LibraryBookmark left, LibraryBookmark right) =>
      _samePosition(left.mediaPosition, right.mediaPosition) &&
      left.label == right.label &&
      left.note == right.note;

  static bool _sameHighlight(LibraryHighlight left, LibraryHighlight right) =>
      _samePosition(left.mediaPosition, right.mediaPosition) &&
      left.quote == right.quote &&
      left.color == right.color &&
      left.note == right.note;

  static WorkAnnotations _mergeAnnotations(
    FundusRemoteWork work,
    WorkAnnotations local,
    WorkAnnotations remote,
  ) {
    final bookmarks = [...remote.bookmarks];
    for (final bookmark in local.bookmarks) {
      if (!bookmarks.any((item) => _sameBookmark(item, bookmark))) {
        bookmarks.add(bookmark);
      }
    }
    final highlights = [...remote.highlights];
    for (final highlight in local.highlights) {
      if (!highlights.any((item) => _sameHighlight(item, highlight))) {
        highlights.add(highlight);
      }
    }
    return WorkAnnotations(
      tags: {...work.tags, ...local.tags, ...remote.tags}.toList(),
      notes: remote.notes,
      bookmarks: bookmarks,
      highlights: highlights,
    );
  }

  Future<String?> _showMobilePublicationDetails({
    required FundusRemoteServer server,
    required FundusRemoteLibrary library,
    required FundusRemoteWork work,
    required List<FundusRemoteTrack> tracks,
    required MediaPosition? progressPosition,
    required int progressIndex,
    required WorkAnnotations annotations,
    required bool isOffline,
    required bool progressHistoryAvailable,
    required FundusOfflineWork? offlineWork,
    required Future<WorkAnnotations> Function(String markdown) onSaveNote,
    required Future<WorkAnnotations> Function(Set<String> tags) onSaveTags,
  }) {
    final epubTrack = tracks
        .where((track) => track.title.toLowerCase().endsWith('.epub'))
        .firstOrNull;
    Future<EpubPublication> Function()? epubPublicationLoader;
    if (epubTrack != null) {
      epubPublicationLoader = () async {
        final offlineTrack = offlineWork?.tracks
            .where((track) => track.id == epubTrack.id)
            .firstOrNull;
        final file = offlineTrack == null
            ? await _cachedRemoteDocument(server, library, epubTrack)
            : File(offlineTrack.path);
        return loadEpubPublication(file.path);
      };
    }
    return Navigator.of(context).push<String>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (pageContext) => _MobileRemotePublicationDetails(
          work: work,
          detail: offlineWork == null
              ? WorkDetailViewModel.fromRemote(
                  work,
                  serverId: server.id,
                  libraryId: library.id,
                  serverName: server.name,
                  libraryName: library.name,
                  offlineAvailable: isOffline,
                )
              : WorkDetailViewModel.fromOffline(offlineWork),
          tracks: tracks,
          relatedWorks: _works,
          progressPosition: progressPosition,
          progressIndex: progressIndex,
          annotations: annotations,
          isOffline: isOffline,
          progressHistoryAvailable: progressHistoryAvailable,
          epubPublicationLoader: epubPublicationLoader,
          onSaveNote: onSaveNote,
          onSaveTags: onSaveTags,
          coverBuilder: () => offlineWork?.coverPath != null
              ? Image.file(File(offlineWork!.coverPath!), fit: BoxFit.cover)
              : work.hasCover
              ? _remoteCover(
                  server,
                  library,
                  work,
                  borderRadius: BorderRadius.circular(14),
                )
              : Icon(_kindIcon(work.kind), size: 72),
        ),
      ),
    );
  }

  Future<void> _showWork(
    FundusRemoteServer server,
    FundusRemoteLibrary library,
    FundusRemoteWork work, {
    bool forceOffline = false,
  }) async {
    if (!widget.showHhh && work.isHhh) return;
    final pageContext = context;
    final mobilePublicationLayout = MediaQuery.sizeOf(pageContext).width < 760;
    final key = _offlineKey(server, library, work);
    final isOffline = _offlineKeys.contains(key);
    final isDocument = _isDocumentKind(work.kind);
    var detailTracks = <FundusRemoteTrack>[];
    FundusOfflineWork? offlineWork;
    MediaPosition? documentPosition;
    String? documentProgressFileId;
    if (isOffline) {
      offlineWork = await _offlineStore.lookup(
        serverId: server.id,
        libraryId: library.id,
        workId: work.id,
      );
      detailTracks = [
        for (final track in offlineWork?.tracks ?? const <FundusOfflineTrack>[])
          FundusRemoteTrack(
            id: track.id,
            title: track.title,
            position: track.position,
            duration: track.duration,
            audioMetadata: track.audioMetadata,
            episode: parseVideoEpisode(track.title),
          ),
      ];
    } else {
      if (!forceOffline) {
        try {
          final result = await _runWithReconnect(
            server,
            (active) => _client.work(active, library.id, work),
          );
          detailTracks = result.value.tracks;
        } catch (_) {
          // Summary details remain usable if the server becomes unavailable.
        }
      }
    }
    final syncAnnotations = await AnnotationSyncSettings.enabled();
    if (isDocument) {
      if (offlineWork != null) {
        final offlineProgress = await _offlineStore.loadProgress(
          serverId: server.id,
          libraryId: library.id,
          workId: work.id,
        );
        documentPosition = offlineProgress?.mediaPosition;
        documentProgressFileId = offlineProgress?.fileId;
      }
      if (!forceOffline) {
        try {
          final result = await _runWithReconnect(
            server,
            (active) => _client.progress(active, library.id, work.id),
          );
          server = result.server;
          documentPosition ??= result.value?.mediaPosition;
          documentProgressFileId ??= result.value?.fileId;
        } catch (_) {
          // Offline reading remains available without the server.
        }
      }
    }
    final documentProgressIndex = detailTracks.indexWhere(
      (track) => track.id == documentProgressFileId,
    );
    var readerAnnotations = isDocument
        ? await _offlineStore.loadAnnotations(
            serverId: server.id,
            libraryId: library.id,
            workId: work.id,
          )
        : const WorkAnnotations();
    if (isDocument && !forceOffline) {
      try {
        final localAnnotations = readerAnnotations;
        final result = await _runWithReconnect(
          server,
          (active) => _client.annotations(active, library.id, work.id),
        );
        server = result.server;
        var remoteAnnotations = result.value;
        for (final note in localAnnotations.notes) {
          if (remoteAnnotations.notes.any(
            (remote) => remote.markdown.trim() == note.markdown.trim(),
          )) {
            continue;
          }
          remoteAnnotations = await _client.saveNote(
            server,
            libraryId: library.id,
            workId: work.id,
            markdown: note.markdown,
          );
        }
        for (final bookmark in localAnnotations.bookmarks) {
          if (remoteAnnotations.bookmarks.any(
            (remote) => _sameBookmark(remote, bookmark),
          )) {
            continue;
          }
          remoteAnnotations = await _client.saveBookmark(
            server,
            libraryId: library.id,
            workId: work.id,
            fileId: bookmark.fileId ?? bookmark.mediaPosition.fileId ?? '',
            position: bookmark.mediaPosition,
            label: bookmark.label,
            note: bookmark.note,
          );
        }
        for (final highlight in localAnnotations.highlights) {
          if (remoteAnnotations.highlights.any(
            (remote) => _sameHighlight(remote, highlight),
          )) {
            continue;
          }
          remoteAnnotations = await _client.saveHighlight(
            server,
            libraryId: library.id,
            workId: work.id,
            fileId: highlight.fileId ?? highlight.mediaPosition.fileId ?? '',
            position: highlight.mediaPosition,
            quote: highlight.quote,
            color: highlight.color,
            note: highlight.note,
          );
        }
        readerAnnotations = _mergeAnnotations(
          work,
          localAnnotations,
          remoteAnnotations,
        );
        await _offlineStore.cacheAnnotations(
          serverId: server.id,
          libraryId: library.id,
          workId: work.id,
          annotations: readerAnnotations,
        );
      } catch (_) {
        // Locally cached notes remain usable while the server is unavailable.
      }
    }
    // Video works are presented like a Plex season list by default. Documents
    // retain their natural file order; both can be changed from the sort menu.
    var trackSort = isDocument
        ? _DocumentTrackSort.oldestFirst
        : _DocumentTrackSort.seasonEpisode;
    if (!pageContext.mounted) return;
    String? action;
    if (mobilePublicationLayout && isDocument) {
      action = await _showMobilePublicationDetails(
        server: server,
        library: library,
        work: work,
        tracks: detailTracks,
        progressPosition: documentPosition,
        progressIndex: documentProgressIndex,
        annotations: readerAnnotations,
        isOffline: isOffline,
        progressHistoryAvailable: !forceOffline,
        offlineWork: offlineWork,
        onSaveNote: (markdown) async {
          if (!syncAnnotations) {
            return _offlineStore.saveWorkNote(
              serverId: server.id,
              libraryId: library.id,
              workId: work.id,
              markdown: markdown,
            );
          }
          try {
            final result = await _runWithReconnect(
              server,
              (active) => _client.saveNote(
                active,
                libraryId: library.id,
                workId: work.id,
                markdown: markdown,
              ),
            );
            server = result.server;
            final merged = WorkAnnotations(
              tags: result.value.tags,
              notes: result.value.notes,
              bookmarks: readerAnnotations.bookmarks,
              highlights: readerAnnotations.highlights,
            );
            await _offlineStore.cacheAnnotations(
              serverId: server.id,
              libraryId: library.id,
              workId: work.id,
              annotations: merged,
            );
            return merged;
          } catch (_) {
            return _offlineStore.saveWorkNote(
              serverId: server.id,
              libraryId: library.id,
              workId: work.id,
              markdown: markdown,
            );
          }
        },
        onSaveTags: (tags) async {
          if (!syncAnnotations) {
            return _offlineStore.replaceWorkTags(
              serverId: server.id,
              libraryId: library.id,
              workId: work.id,
              tags: tags,
            );
          }
          try {
            final result = await _runWithReconnect(
              server,
              (active) => _client.saveTags(
                active,
                libraryId: library.id,
                workId: work.id,
                tags: tags,
              ),
            );
            server = result.server;
            final merged = WorkAnnotations(
              tags: result.value.tags,
              notes: readerAnnotations.notes,
              bookmarks: readerAnnotations.bookmarks,
              highlights: readerAnnotations.highlights,
            );
            await _offlineStore.cacheAnnotations(
              serverId: server.id,
              libraryId: library.id,
              workId: work.id,
              annotations: merged,
            );
            return merged;
          } catch (_) {
            return _offlineStore.replaceWorkTags(
              serverId: server.id,
              libraryId: library.id,
              workId: work.id,
              tags: tags,
            );
          }
        },
      );
    } else {
      if (!pageContext.mounted) return;
      action = await showModalBottomSheet<String>(
        context: pageContext,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (context) => StatefulBuilder(
          builder: (context, setSheetState) {
            final orderedTracks = _orderedRemoteTracks(detailTracks, trackSort);
            final trackRows = <Widget>[];
            int? lastSeason;
            final detail = WorkDetailViewModel.fromRemote(
              work,
              serverId: server.id,
              libraryId: library.id,
              serverName: server.name,
              libraryName: library.name,
              offlineAvailable: isOffline,
            );
            for (final entry in orderedTracks) {
              final episode =
                  entry.track.episode ?? parseVideoEpisode(entry.track.title);
              if (trackSort == _DocumentTrackSort.seasonEpisode &&
                  episode != null &&
                  episode.season != lastSeason) {
                lastSeason = episode.season;
                trackRows.add(
                  Padding(
                    padding: const EdgeInsets.only(top: 8, bottom: 2),
                    child: Text(
                      episode.special
                          ? 'Specials'
                          : 'Staffel ${episode.season}',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ),
                );
              }
              final readState = documentChapterReadState(
                chapterIndex: entry.originalIndex,
                currentChapterIndex: documentProgressIndex,
                workFinished: work.progressFinished,
                currentPosition: documentPosition,
              );
              trackRows.add(
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: documentChapterLeading(
                    context,
                    entry.originalIndex + 1,
                    readState,
                  ),
                  title: Text(
                    _remoteTrackLabel(entry.track),
                    style: documentChapterTitleStyle(context, readState),
                  ),
                  subtitle: _remoteTechnicalSubtitle(entry.track),
                  trailing: isDocument
                      ? const Icon(Icons.open_in_new)
                      : entry.track.duration == null
                      ? null
                      : Text(_formatRemoteDuration(entry.track.duration!)),
                  onTap: () =>
                      Navigator.pop(context, 'open:${entry.originalIndex}'),
                ),
              );
            }
            return SafeArea(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    WorkDetailHeader(
                      detail: detail,
                      breadcrumbs: _remoteDetailBreadcrumbs(detail),
                      coverBuilder: (_) => work.hasCover
                          ? _remoteCover(
                              server,
                              library,
                              work,
                              borderRadius: BorderRadius.circular(14),
                            )
                          : Icon(_kindIcon(work.kind), size: 72),
                      primaryAction: WorkDetailHeaderAction(
                        label: isDocument
                            ? (documentPosition == null
                                  ? 'Lesen'
                                  : 'Fortsetzen')
                            : (work.progressPosition == null
                                  ? 'Abspielen'
                                  : 'Fortsetzen'),
                        icon: isDocument
                            ? Icons.menu_book_outlined
                            : Icons.play_arrow,
                        onPressed: detailTracks.isEmpty
                            ? null
                            : () => Navigator.pop(
                                context,
                                isDocument ? 'open:resume' : 'play',
                              ),
                      ),
                      secondaryAction: WorkDetailHeaderAction(
                        label: isOffline
                            ? 'Download verwalten'
                            : 'Offline speichern',
                        icon: isOffline
                            ? Icons.download_done
                            : Icons.download_outlined,
                        onPressed: () => Navigator.pop(
                          context,
                          isOffline ? 'remove_download' : 'download',
                        ),
                      ),
                    ),
                    if (isDocument && !forceOffline)
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton.icon(
                          onPressed: () =>
                              Navigator.pop(context, 'progress_history'),
                          icon: const Icon(Icons.history),
                          label: const Text('Gerätestände'),
                        ),
                      ),
                    const SizedBox(height: 18),
                    WorkDetailFacts(detail: detail, progress: documentPosition),
                    if (_remoteVideoCredits(
                      work.providerMetadata,
                    ).isNotEmpty) ...[
                      const SizedBox(height: 18),
                      Text(
                        'Besetzung & Crew',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          for (final credit in _remoteVideoCredits(
                            work.providerMetadata,
                          ))
                            ActionChip(
                              avatar: _remoteCreditAvatar(credit),
                              label: Text(
                                credit.role == null ||
                                        credit.role!.trim().isEmpty
                                    ? credit.name
                                    : '${credit.name} · ${credit.role}',
                              ),
                              onPressed: () => Navigator.pop(
                                context,
                                'credit:${credit.name}',
                              ),
                            ),
                        ],
                      ),
                    ],
                    if (_remoteTrailerUrl(work.providerMetadata)
                        case final trailer?)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                          onPressed: () => _copyRemoteTrailer(context, trailer),
                          icon: const Icon(Icons.ondemand_video),
                          label: const Text('Trailer-Link kopieren'),
                        ),
                      ),
                    if (work.progressPosition case final position?) ...[
                      const SizedBox(height: 16),
                      Text(
                        work.progressDuration == null
                            ? 'Fortsetzen bei ${_formatRemoteDuration(position)}'
                            : '${_formatRemoteDuration(position)} / '
                                  '${_formatRemoteDuration(work.progressDuration!)}',
                        style: Theme.of(context).textTheme.labelLarge,
                      ),
                    ],
                    if (isDocument && detailTracks.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          Expanded(
                            child: FilledButton.icon(
                              onPressed: () =>
                                  Navigator.pop(context, 'open:resume'),
                              icon: const Icon(Icons.menu_book_outlined),
                              label: Text(
                                documentPosition == null
                                    ? 'Lesen'
                                    : 'Fortsetzen',
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          if (isOffline)
                            PopupMenuButton<String>(
                              tooltip: 'Offline-Kopie verwalten',
                              icon: const Icon(Icons.download_done),
                              onSelected: (value) =>
                                  Navigator.pop(context, value),
                              itemBuilder: (context) => const [
                                PopupMenuItem(
                                  value: 'download',
                                  child: ListTile(
                                    leading: Icon(Icons.add_to_photos_outlined),
                                    title: Text('Weitere Kapitel laden'),
                                  ),
                                ),
                                PopupMenuItem(
                                  value: 'remove_download',
                                  child: ListTile(
                                    leading: Icon(Icons.delete_outline),
                                    title: Text('Offline-Kopie löschen'),
                                  ),
                                ),
                              ],
                            )
                          else
                            IconButton.filledTonal(
                              onPressed: () =>
                                  Navigator.pop(context, 'download'),
                              tooltip: 'Kapitel offline speichern',
                              icon: const Icon(Icons.download_outlined),
                            ),
                        ],
                      ),
                      if (!forceOffline) ...[
                        const SizedBox(height: 8),
                        Align(
                          alignment: Alignment.centerRight,
                          child: TextButton.icon(
                            onPressed: () =>
                                Navigator.pop(context, 'progress_history'),
                            icon: const Icon(Icons.history),
                            label: const Text('Gerätestände'),
                          ),
                        ),
                      ],
                    ],
                    if (work.description case final description?) ...[
                      const SizedBox(height: 20),
                      Text(description),
                    ],
                    if (detailTracks.isNotEmpty) ...[
                      const SizedBox(height: 20),
                      Row(
                        children: [
                          Text(
                            'Dateien',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const Spacer(),
                          PopupMenuButton<_DocumentTrackSort>(
                            tooltip: 'Dateien sortieren',
                            initialValue: trackSort,
                            onSelected: (value) =>
                                setSheetState(() => trackSort = value),
                            itemBuilder: (context) => const [
                              PopupMenuItem(
                                value: _DocumentTrackSort.oldestFirst,
                                child: Text('Älteste Kapitel zuerst'),
                              ),
                              PopupMenuItem(
                                value: _DocumentTrackSort.newestFirst,
                                child: Text('Neueste Kapitel zuerst'),
                              ),
                              PopupMenuItem(
                                value: _DocumentTrackSort.seasonEpisode,
                                child: Text('Staffel/Folge'),
                              ),
                              PopupMenuItem(
                                value: _DocumentTrackSort.titleAscending,
                                child: Text('Name A–Z'),
                              ),
                            ],
                            icon: const Icon(Icons.sort),
                          ),
                        ],
                      ),
                      ...trackRows,
                    ],
                    const SizedBox(height: 24),
                  ],
                ),
              ),
            );
          },
        ),
      );
    }
    if (action == null) {
      if (forceOffline) return;
      try {
        final result = await _runWithReconnect(
          server,
          (active) => _client.works(active, library.id),
        );
        if (mounted) {
          setState(() {
            _selectedServer = result.server;
            _works = _visibleWorks(result.value);
          });
        }
      } catch (_) {}
      return;
    }
    if (action == 'progress_history') {
      final restoredPosition = await _showRemoteReaderProgressHistory(
        server,
        library,
        work,
        detailTracks,
      );
      if (restoredPosition == null || !mounted) return;
      final restoredTrack = detailTracks
          .where((track) => track.id == restoredPosition.fileId)
          .firstOrNull;
      final title = restoredTrack?.title.toLowerCase() ?? '';
      if (title.endsWith('.cbz')) {
        await _openRemoteComicWork(
          server,
          library,
          work,
          detailTracks,
          offlineWork: offlineWork,
          startFileId: restoredPosition.fileId,
        );
      } else if (title.endsWith('.pdf')) {
        await _openRemotePdfWork(
          server,
          library,
          work,
          detailTracks,
          offlineWork: offlineWork,
          startFileId: restoredPosition.fileId,
        );
      } else if (title.endsWith('.epub')) {
        await _openRemoteEpubWork(
          server,
          library,
          work,
          detailTracks,
          offlineWork: offlineWork,
          startFileId: restoredPosition.fileId,
          startPosition: restoredPosition,
        );
      } else {
        await _showWork(server, library, work);
      }
      return;
    }
    if (action.startsWith('credit:')) {
      final credit = action.substring('credit:'.length).trim();
      if (credit.isNotEmpty && mounted) {
        setState(() {
          _selectedCredit = credit;
          _selectedGroup = null;
        });
      }
      return;
    }
    if (action == 'download') {
      if (forceOffline) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Kapitel können wieder am Server verwaltet werden.',
              ),
            ),
          );
        }
        return;
      }
      final selectedTrackIds = isDocument
          ? await _selectDownloadTracks(
              detailTracks,
              currentTrackIndex: documentProgressIndex,
              alreadyDownloadedIds: {
                for (final track
                    in offlineWork?.tracks ?? const <FundusOfflineTrack>[])
                  track.id,
              },
            )
          : null;
      if (isDocument && selectedTrackIds == null) return;
      await _downloadWork(server, library, work, trackIds: selectedTrackIds);
      if (mounted) {
        await _showWork(server, library, work);
      }
      return;
    }
    if (action.startsWith('similar:')) {
      final relatedId = action.substring('similar:'.length);
      final related = _works.where((item) => item.id == relatedId).firstOrNull;
      if (related != null) await _showWork(server, library, related);
      return;
    }
    if (action.startsWith('annotation:')) {
      final annotationId = action.substring('annotation:'.length);
      final bookmark = readerAnnotations.bookmarks
          .where((item) => item.id == annotationId)
          .firstOrNull;
      final highlight = readerAnnotations.highlights
          .where((item) => item.id == annotationId)
          .firstOrNull;
      final position = bookmark?.mediaPosition ?? highlight?.mediaPosition;
      if (position == null) return;
      await _openRemoteEpubWork(
        server,
        library,
        work,
        detailTracks,
        offlineWork: offlineWork,
        startFileId: position.fileId,
        startPosition: position,
        skipServerLookup: offlineWork != null && _selectedServer == null,
      );
      return;
    }
    if (action.startsWith('epub_chapter:')) {
      final chapterIndex = int.tryParse(
        action.substring('epub_chapter:'.length),
      );
      if (chapterIndex == null) return;
      final epub = detailTracks
          .where((track) => track.title.toLowerCase().endsWith('.epub'))
          .firstOrNull;
      if (epub == null) return;
      await _openRemoteEpubWork(
        server,
        library,
        work,
        detailTracks,
        offlineWork: offlineWork,
        startFileId: epub.id,
        initialChapterIndex: chapterIndex,
        skipServerLookup: offlineWork != null && _selectedServer == null,
      );
      return;
    }
    if (action == 'remove_download') {
      await _offlineStore.remove(
        serverId: server.id,
        libraryId: library.id,
        workId: work.id,
      );
      if (mounted) {
        setState(() {
          _offlineKeys.remove(key);
          _offlineWorks = _offlineWorks
              .where(
                (item) =>
                    item.serverId != server.id ||
                    item.libraryId != library.id ||
                    item.workId != work.id,
              )
              .toList();
        });
      }
      return;
    }
    if (action.startsWith('open:')) {
      if (_isRemoteVideoWork(work)) {
        final index = int.tryParse(action.substring('open:'.length));
        final selected =
            index == null || index < 0 || index >= detailTracks.length
            ? null
            : detailTracks[index];
        await _playRemoteVideo(
          server,
          library,
          work,
          offlineWork: offlineWork,
          startFileId: selected?.id,
          // An explicit episode click must not reuse the work-level resume
          // position from another episode.
          startPosition: selected == null ? null : Duration.zero,
        );
        return;
      }
      final target = action.substring(5);
      final resume = target == 'resume';
      final progressFileId = documentProgressFileId ?? documentPosition?.fileId;
      final resumeIndex = detailTracks.indexWhere(
        (track) => track.id == progressFileId,
      );
      final firstReadableIndex = detailTracks.indexWhere((track) {
        final title = track.title.toLowerCase();
        return title.endsWith('.cbz') ||
            title.endsWith('.pdf') ||
            title.endsWith('.epub');
      });
      final index = resume
          ? (resumeIndex < 0 ? firstReadableIndex : resumeIndex)
          : int.tryParse(target);
      if (index == null || index < 0 || index >= detailTracks.length) return;
      if (detailTracks[index].title.toLowerCase().endsWith('.cbz')) {
        await _openRemoteComicWork(
          server,
          library,
          work,
          detailTracks,
          offlineWork: offlineWork,
          startFileId: resume ? null : detailTracks[index].id,
          skipServerLookup: forceOffline,
        );
        return;
      }
      if (detailTracks[index].title.toLowerCase().endsWith('.pdf')) {
        await _openRemotePdfWork(
          server,
          library,
          work,
          detailTracks,
          offlineWork: offlineWork,
          startFileId: resume ? null : detailTracks[index].id,
          skipServerLookup: forceOffline,
        );
      } else if (detailTracks[index].title.toLowerCase().endsWith('.epub')) {
        await _openRemoteEpubWork(
          server,
          library,
          work,
          detailTracks,
          offlineWork: offlineWork,
          startFileId: resume ? null : detailTracks[index].id,
          skipServerLookup: forceOffline,
        );
      } else if (offlineWork != null && index < offlineWork.tracks.length) {
        await _openDocumentPath(offlineWork.tracks[index].path);
      } else {
        await _openRemoteDocument(server, library, detailTracks[index]);
      }
      return;
    }
    if (action != 'play' || !mounted) return;
    if (_isRemoteVideoWork(work)) {
      try {
        await _playRemoteVideo(server, library, work, offlineWork: offlineWork);
      } catch (_) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Video konnte nicht gestartet werden.'),
            ),
          );
        }
      }
      return;
    }
    final player =
        _remotePlayer ??
        FundusRemotePlayerController(
          deviceId: await _store.deviceId(),
          deviceName: await _store.deviceName(),
          offlineStore: _offlineStore,
          onConflict: (conflict) => resolvePlaybackConflict(context, conflict),
          serverResolver: _relocatePlayerServer,
        );
    if (_remotePlayer == null && mounted) {
      setState(() => _remotePlayer = player);
    }
    if (offlineWork != null) {
      await player.open(server, library, work, offlineWork: offlineWork);
      return;
    }
    try {
      final result = await _runWithReconnect(
        server,
        (active) => _client.verifyEndpoint(active, active.baseUri),
      );
      await player.open(result.server, library, work);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Serververbindung nicht verfügbar.')),
      );
    }
  }

  Future<void> _downloadWork(
    FundusRemoteServer server,
    FundusRemoteLibrary library,
    FundusRemoteWork work, {
    Set<String>? trackIds,
  }) async {
    final key = _offlineKey(server, library, work);
    setState(() {
      _downloadingKey = key;
      _downloadCompleted = 0;
      _downloadTotal = 0;
      _downloadReceivedBytes = 0;
      _downloadExpectedBytes = null;
      _lastDownloadUiUpdate = null;
    });
    try {
      unawaited(
        FundusDiagnostics.instance.record('remote.download_started', {
          'server_id': server.id,
          'library_id': library.id,
          'work_id': work.id,
        }),
      );
      final result = await _runWithReconnect(
        server,
        (active) => _offlineStore.download(
          _client,
          active,
          library,
          work,
          trackIds: trackIds,
          onProgress: (completed, total) {
            if (!mounted) return;
            setState(() {
              _downloadCompleted = completed;
              _downloadTotal = total;
            });
          },
          onTransfer: (fileIndex, fileCount, received, expected) {
            if (!mounted) return;
            final now = DateTime.now();
            final last = _lastDownloadUiUpdate;
            if (received != expected &&
                last != null &&
                now.difference(last) < const Duration(milliseconds: 200)) {
              return;
            }
            _lastDownloadUiUpdate = now;
            setState(() {
              _downloadCompleted = fileIndex;
              _downloadTotal = fileCount;
              _downloadReceivedBytes = received;
              _downloadExpectedBytes = expected;
            });
          },
        ),
      );
      final offline = result.value;
      unawaited(
        FundusDiagnostics.instance.record('remote.download_completed', {
          'server_id': result.server.id,
          'library_id': library.id,
          'work_id': work.id,
          'file_count': offline.tracks.length,
        }),
      );
      if (!mounted) return;
      setState(() {
        _offlineKeys.add(key);
        _offlineWorks = [
          offline,
          ..._offlineWorks.where(
            (item) =>
                item.serverId != offline.serverId ||
                item.libraryId != offline.libraryId ||
                item.workId != offline.workId,
          ),
        ];
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('„${work.title}“ ist jetzt offline verfügbar.')),
      );
    } catch (error) {
      unawaited(
        FundusDiagnostics.instance.record('remote.download_failed', {
          'server_id': server.id,
          'library_id': library.id,
          'work_id': work.id,
          'reason': _safeNetworkError(error),
        }),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Offline-Download fehlgeschlagen.')),
      );
    } finally {
      if (mounted) setState(() => _downloadingKey = null);
    }
  }

  Future<Set<String>?> _selectDownloadTracks(
    List<FundusRemoteTrack> tracks, {
    required int currentTrackIndex,
    Set<String> alreadyDownloadedIds = const {},
  }) async {
    if (tracks.isEmpty || !mounted) return null;
    final firstUnread = currentTrackIndex < 0
        ? 0
        : currentTrackIndex.clamp(0, tracks.length - 1);
    var range = RangeValues(
      firstUnread.toDouble(),
      (firstUnread + 99).clamp(0, tracks.length - 1).toDouble(),
    );
    var mode = _ChapterSelectionMode.range;
    final individual = <int>{};
    final startController = TextEditingController(text: '${firstUnread + 1}');
    final endController = TextEditingController(
      text: '${range.end.round() + 1}',
    );
    final selected = await showDialog<Set<String>>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) {
          void select(int start, int end) => setDialogState(() {
            range = RangeValues(
              start.clamp(0, tracks.length - 1).toDouble(),
              end.clamp(0, tracks.length - 1).toDouble(),
            );
            startController.text = '${range.start.round() + 1}';
            endController.text = '${range.end.round() + 1}';
          });

          void applyExactRange() {
            final start = int.tryParse(startController.text.trim());
            final end = int.tryParse(endController.text.trim());
            if (start == null || end == null) return;
            final indexes = chapterSelectionRange(
              total: tracks.length,
              start: start,
              end: end,
            ).toList()..sort();
            select(indexes.first, indexes.last);
          }

          final start = range.start.round();
          final end = range.end.round();
          final rangeIndexes = chapterSelectionRange(
            total: tracks.length,
            start: start + 1,
            end: end + 1,
          );
          final selectedIndexes = mode == _ChapterSelectionMode.range
              ? rangeIndexes
              : individual;
          final newIndexes = selectedIndexes
              .where(
                (index) => !alreadyDownloadedIds.contains(tracks[index].id),
              )
              .toSet();
          return AlertDialog(
            scrollable: true,
            icon: const Icon(Icons.download_for_offline_outlined),
            title: const Text('Kapitel offline speichern'),
            content: SizedBox(
              width: 520,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Wähle einen Bereich oder stelle eine individuelle '
                    'Kapitelauswahl zusammen. Bereits vorhandene Downloads '
                    'werden dabei nicht erneut übertragen.',
                  ),
                  const SizedBox(height: 12),
                  SegmentedButton<_ChapterSelectionMode>(
                    segments: const [
                      ButtonSegment(
                        value: _ChapterSelectionMode.range,
                        icon: Icon(Icons.linear_scale),
                        label: Text('Bereich'),
                      ),
                      ButtonSegment(
                        value: _ChapterSelectionMode.individual,
                        icon: Icon(Icons.checklist),
                        label: Text('Einzeln'),
                      ),
                    ],
                    selected: {mode},
                    onSelectionChanged: (selection) => setDialogState(() {
                      mode = selection.single;
                      if (mode == _ChapterSelectionMode.individual &&
                          individual.isEmpty) {
                        individual.addAll(rangeIndexes);
                      }
                    }),
                  ),
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      ActionChip(
                        label: const Text('Nächste 100'),
                        onPressed: () {
                          mode = _ChapterSelectionMode.range;
                          select(firstUnread, firstUnread + 99);
                        },
                      ),
                      ActionChip(
                        label: const Text('Ab aktuellem Kapitel'),
                        onPressed: () {
                          mode = _ChapterSelectionMode.range;
                          select(firstUnread, tracks.length - 1);
                        },
                      ),
                      ActionChip(
                        label: const Text('Alle'),
                        onPressed: () {
                          mode = _ChapterSelectionMode.range;
                          select(0, tracks.length - 1);
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  if (mode == _ChapterSelectionMode.range) ...[
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: startController,
                            keyboardType: TextInputType.number,
                            inputFormatters: [
                              FilteringTextInputFormatter.digitsOnly,
                            ],
                            decoration: const InputDecoration(
                              labelText: 'Von Kapitel',
                              border: OutlineInputBorder(),
                            ),
                            onSubmitted: (_) => applyExactRange(),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: TextField(
                            controller: endController,
                            keyboardType: TextInputType.number,
                            inputFormatters: [
                              FilteringTextInputFormatter.digitsOnly,
                            ],
                            decoration: const InputDecoration(
                              labelText: 'Bis Kapitel',
                              border: OutlineInputBorder(),
                            ),
                            onSubmitted: (_) => applyExactRange(),
                          ),
                        ),
                        IconButton(
                          onPressed: applyExactRange,
                          tooltip: 'Exakten Bereich übernehmen',
                          icon: const Icon(Icons.check),
                        ),
                      ],
                    ),
                    RangeSlider(
                      values: range,
                      min: 0,
                      max: (tracks.length - 1).toDouble(),
                      divisions: tracks.length > 1 ? tracks.length - 1 : null,
                      labels: RangeLabels('${start + 1}', '${end + 1}'),
                      onChanged: tracks.length > 1
                          ? (value) =>
                                select(value.start.round(), value.end.round())
                          : null,
                    ),
                    Text(
                      '${tracks[start].title}\n–\n${tracks[end].title}',
                      maxLines: 5,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ] else ...[
                    Row(
                      children: [
                        Text('${individual.length} Kapitel ausgewählt'),
                        const Spacer(),
                        TextButton(
                          onPressed: () => setDialogState(individual.clear),
                          child: const Text('Keine'),
                        ),
                      ],
                    ),
                    SizedBox(
                      height: 300,
                      child: ListView.builder(
                        itemCount: tracks.length,
                        itemBuilder: (context, index) {
                          final downloaded = alreadyDownloadedIds.contains(
                            tracks[index].id,
                          );
                          return CheckboxListTile(
                            dense: true,
                            value: individual.contains(index),
                            secondary: downloaded
                                ? const Icon(Icons.download_done, size: 20)
                                : null,
                            title: Text(
                              tracks[index].title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: downloaded
                                ? const Text('Bereits offline')
                                : null,
                            onChanged: (checked) => setDialogState(() {
                              checked == true
                                  ? individual.add(index)
                                  : individual.remove(index);
                            }),
                          );
                        },
                      ),
                    ),
                  ],
                  const SizedBox(height: 8),
                  Text(
                    '${selectedIndexes.length} ausgewählt · '
                    '${newIndexes.length} neu herunterzuladen',
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Abbrechen'),
              ),
              FilledButton.icon(
                onPressed: newIndexes.isEmpty
                    ? null
                    : () => Navigator.pop(dialogContext, {
                        for (final index in newIndexes) tracks[index].id,
                      }),
                icon: const Icon(Icons.download),
                label: Text('${newIndexes.length} herunterladen'),
              ),
            ],
          );
        },
      ),
    );
    startController.dispose();
    endController.dispose();
    return selected;
  }

  double? get _downloadProgress {
    if (_downloadTotal <= 0) return null;
    final expected = _downloadExpectedBytes;
    final withinFile = expected != null && expected > 0
        ? (_downloadReceivedBytes / expected).clamp(0.0, 1.0)
        : 0.0;
    return ((_downloadCompleted + withinFile) / _downloadTotal).clamp(0.0, 1.0);
  }

  String get _downloadLabel {
    if (_downloadTotal <= 0) return 'Offline-Download wird vorbereitet …';
    final current = (_downloadCompleted + 1).clamp(1, _downloadTotal);
    final expected = _downloadExpectedBytes;
    if (expected != null && expected > 0) {
      final percent = ((_downloadReceivedBytes / expected) * 100)
          .clamp(0, 100)
          .round();
      return 'Offline-Download: Datei $current/$_downloadTotal · $percent %';
    }
    return 'Offline-Download: Datei $current/$_downloadTotal';
  }

  Widget _remoteCover(
    FundusRemoteServer server,
    FundusRemoteLibrary library,
    FundusRemoteWork work, {
    BorderRadius? borderRadius,
  }) {
    final key = '${server.id}/${library.id}/${work.id}';
    final future = _coverRequests.putIfAbsent(
      key,
      () => _loadCoverWithRetry(server, library, work),
    );
    return FutureBuilder<Uint8List>(
      future: future,
      builder: (context, snapshot) {
        if (snapshot.hasData) {
          final image = Image.memory(snapshot.data!, fit: BoxFit.cover);
          return borderRadius == null
              ? image
              : ClipRRect(borderRadius: borderRadius, child: image);
        }
        if (snapshot.hasError) {
          return Center(
            child: IconButton(
              tooltip: 'Cover erneut laden',
              onPressed: () => setState(() => _coverRequests.remove(key)),
              icon: const Icon(Icons.refresh),
            ),
          );
        }
        return const Center(child: CircularProgressIndicator());
      },
    );
  }

  Future<Uint8List> _loadCoverWithRetry(
    FundusRemoteServer server,
    FundusRemoteLibrary library,
    FundusRemoteWork work,
  ) async {
    Object? lastError;
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        final result = await _runWithReconnect(
          server,
          (active) => _client.cover(active, library.id, work.id),
        );
        return result.value;
      } on FundusRemoteRequestException catch (error) {
        // A missing/forbidden cover is a permanent response. Retrying it and
        // relocating the server created hundreds of requests and could block
        // both Flutter clients while the embedded server handled the storm.
        if (error.statusCode >= 400 && error.statusCode < 500) rethrow;
        lastError = error;
        if (attempt < 2) {
          await Future<void>.delayed(Duration(milliseconds: 250 << attempt));
        }
      } catch (error) {
        lastError = error;
        if (attempt < 2) {
          await Future<void>.delayed(Duration(milliseconds: 250 << attempt));
        }
      }
    }
    throw lastError ??
        const HttpException('Cover konnte nicht geladen werden.');
  }

  Future<({FundusRemoteServer server, T value})> _runWithReconnect<T>(
    FundusRemoteServer server,
    Future<T> Function(FundusRemoteServer server) operation, {
    bool retryNotFound = false,
  }) async {
    try {
      final value = await operation(server);
      _setServerOnline(true);
      return (server: server, value: value);
    } on FundusRemoteRequestException catch (error) {
      // Relocation can only help transport/server failures. Callers may opt
      // into retrying 404 for reconnect-sensitive catalog probes; permanent
      // 4xx responses remain visible immediately by default.
      if (error.statusCode >= 400 &&
          error.statusCode < 500 &&
          !(retryNotFound && error.statusCode == HttpStatus.notFound)) {
        if (error.statusCode == HttpStatus.unauthorized ||
            error.statusCode == HttpStatus.forbidden) {
          if (mounted) setState(() => _authorizationRequired = true);
        }
        _setServerOnline(
          error.statusCode != HttpStatus.unauthorized &&
              error.statusCode != HttpStatus.forbidden,
        );
        rethrow;
      }
      return _retryAfterRelocation(server, operation, error);
    } catch (firstError) {
      return _retryAfterRelocation(server, operation, firstError);
    }
  }

  void _setServerOnline(bool value) {
    if (!mounted ||
        (_serverOnline == value && !(value && _authorizationRequired))) {
      return;
    }
    setState(() {
      _serverOnline = value;
      if (value) _authorizationRequired = false;
    });
  }

  Future<void> _refreshServerConnection() async {
    final selected = _selectedServer ?? _heartbeatServer;
    if (selected == null || _busy) return;
    try {
      final result = await _runWithReconnect(
        selected,
        (active) => _client.libraries(active),
        retryNotFound: true,
      );
      if (mounted && result.server.baseUri != selected.baseUri) {
        setState(() => _selectedServer = result.server);
      }
    } catch (_) {
      _setServerOnline(false);
    }
  }

  Future<({FundusRemoteServer server, T value})> _retryAfterRelocation<T>(
    FundusRemoteServer server,
    Future<T> Function(FundusRemoteServer server) operation,
    Object firstError,
  ) async {
    unawaited(
      FundusDiagnostics.instance.record('remote.reconnect_started', {
        'server_id': server.id,
        'reason': _safeNetworkError(firstError),
      }),
    );
    final relocated = await _resolveShared(server);
    await _replaceServer(relocated);
    try {
      final value = await operation(relocated);
      _setServerOnline(true);
      unawaited(
        FundusDiagnostics.instance.record('remote.reconnect_completed', {
          'server_id': server.id,
          'endpoint_changed': relocated.baseUri != server.baseUri,
        }),
      );
      return (server: relocated, value: value);
    } catch (retryError) {
      _setServerOnline(false);
      unawaited(
        FundusDiagnostics.instance.record('remote.reconnect_failed', {
          'server_id': server.id,
          'reason': _safeNetworkError(retryError),
        }),
      );
      rethrow;
    }
  }

  Future<FundusRemoteServer> _resolveShared(FundusRemoteServer server) {
    final known = _servers.where((item) => item.id == server.id).firstOrNull;
    final candidate = known ?? server;
    return _reconnects.putIfAbsent(server.id, () {
      final operation = _peerDiscovery.resolve(candidate);
      operation.then<void>(
        (_) {
          _reconnects.remove(server.id);
        },
        onError: (_) {
          _reconnects.remove(server.id);
        },
      );
      return operation;
    });
  }

  Future<void> _replaceServer(FundusRemoteServer server) async {
    final updated = [
      for (final item in _servers) item.id == server.id ? server : item,
    ];
    await _store.save(updated);
    if (!mounted) return;
    setState(() {
      _servers = updated;
      if (_selectedServer?.id == server.id) _selectedServer = server;
    });
  }

  Future<FundusRemoteServer> _relocatePlayerServer(
    FundusRemoteServer server,
  ) async {
    final relocated = await _resolveShared(server);
    await _replaceServer(relocated);
    return relocated;
  }

  static String _safeNetworkError(Object error) => switch (error) {
    SocketException(:final osError) =>
      'socket_${osError?.errorCode ?? 'unknown'}',
    TlsException() => 'tls',
    HttpException() => 'http',
    FileSystemException() => 'filesystem',
    _ => error.runtimeType.toString(),
  };

  static String _offlineKey(
    FundusRemoteServer server,
    FundusRemoteLibrary library,
    FundusRemoteWork work,
  ) => '${server.id}/${library.id}/${work.id}';

  static String _kindLabel(String kind) => switch (kind) {
    'audiobook' || 'audio' => 'Hörbuch',
    'movie' || 'video' => 'Film',
    'series' || 'tv' => 'Serie',
    'podcast' => 'Podcast',
    'music' => 'Musik',
    'ebook' || 'book' => 'E-Book',
    'webnovel' => 'Webnovel',
    'manga' => 'Manga/Comic',
    'image' => 'Bild',
    'document' || 'archive' => 'Dokument',
    _ => kind,
  };

  static IconData _kindIcon(String kind) => switch (kind) {
    'movie' || 'video' || 'series' || 'tv' => Icons.movie_outlined,
    'podcast' => Icons.podcasts_outlined,
    'music' => Icons.music_note_outlined,
    'ebook' || 'book' => Icons.menu_book_outlined,
    'webnovel' => Icons.chrome_reader_mode_outlined,
    'manga' => Icons.auto_stories_outlined,
    'image' => Icons.image_outlined,
    'document' || 'archive' => Icons.description_outlined,
    _ => Icons.audiotrack,
  };

  static bool _isDocumentKind(String kind) => const {
    'ebook',
    'webnovel',
    'manga',
    'image',
    'document',
    'ttrpg_product',
    'archive',
  }.contains(kind);

  Future<void> _openRemoteDocument(
    FundusRemoteServer server,
    FundusRemoteLibrary library,
    FundusRemoteTrack track,
  ) async {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      SnackBar(
        duration: const Duration(minutes: 2),
        content: Text('„${track.title}“ wird für die Vorschau geladen …'),
      ),
    );
    try {
      final file = await _documentCache.obtain(
        cacheKey: '${server.id}/${library.id}/${track.id}',
        filename: track.title,
        open: () async {
          final result = await _runWithReconnect(
            server,
            (active) => _client.openContent(
              active,
              libraryId: library.id,
              fileId: track.id,
            ),
          );
          final remote = result.value;
          return FundusRemoteDocumentSource(
            bytes: remote.response,
            contentLength: remote.response.contentLength > 0
                ? remote.response.contentLength
                : null,
            close: remote.close,
          );
        },
      );
      messenger.hideCurrentSnackBar();
      await _openDocumentPath(file.path);
    } catch (error) {
      messenger.hideCurrentSnackBar();
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            error is FundusRemoteDocumentException
                ? error.message
                : 'Die Datei konnte nicht vom Server geladen werden.',
          ),
        ),
      );
    }
  }

  Future<File> _cachedRemoteDocument(
    FundusRemoteServer server,
    FundusRemoteLibrary library,
    FundusRemoteTrack track,
  ) => _documentCache.obtain(
    cacheKey: '${server.id}/${library.id}/${track.id}',
    filename: track.title,
    open: () async {
      final result = await _runWithReconnect(
        server,
        (active) => _client.openContent(
          active,
          libraryId: library.id,
          fileId: track.id,
        ),
      );
      final remote = result.value;
      return FundusRemoteDocumentSource(
        bytes: remote.response,
        contentLength: remote.response.contentLength > 0
            ? remote.response.contentLength
            : null,
        close: remote.close,
      );
    },
  );

  Future<void> _openRemoteComicWork(
    FundusRemoteServer server,
    FundusRemoteLibrary library,
    FundusRemoteWork work,
    List<FundusRemoteTrack> tracks, {
    required FundusOfflineWork? offlineWork,
    String? startFileId,
    bool skipServerLookup = false,
  }) async {
    final comics =
        tracks
            .where((track) => track.title.toLowerCase().endsWith('.cbz'))
            .toList(growable: false)
          ..sort((left, right) => left.position.compareTo(right.position));
    if (comics.isEmpty) return;

    final localProgress = await _offlineStore.loadProgress(
      serverId: server.id,
      libraryId: library.id,
      workId: work.id,
    );
    FundusRemoteProgress? serverProgress;
    if (!skipServerLookup) {
      try {
        final result = await _runWithReconnect(
          server,
          (active) => _client.progress(active, library.id, work.id),
        );
        server = result.server;
        serverProgress = result.value;
      } catch (_) {}
    }
    var progress = serverProgress ?? localProgress;
    var selectedDeviceProgress = false;
    final localPosition = localProgress?.mediaPosition;
    final serverPosition = serverProgress?.mediaPosition;
    final deviceId = await _store.deviceId();
    if (shouldResolveReaderProgressConflict(
      localPendingSync: localProgress?.pendingSync ?? false,
      devicePosition: localPosition,
      serverPosition: serverPosition,
    )) {
      final localDeviceName = await _store.deviceName();
      if (!mounted) return;
      final choice = await resolveReaderProgressConflict(
        context,
        devicePosition: localPosition!,
        serverPosition: serverPosition!,
        deviceName: localDeviceName,
        serverDeviceName: serverProgress?.deviceName ?? server.name,
      );
      progress = choice == ReaderProgressConflictChoice.keepDevice
          ? localProgress
          : serverProgress;
      selectedDeviceProgress =
          choice == ReaderProgressConflictChoice.keepDevice;
    }
    final storedPosition = progress?.mediaPosition;
    var chapterIndex = comics.indexWhere(
      (track) => track.id == (startFileId ?? progress?.fileId),
    );
    if (chapterIndex < 0) chapterIndex = 0;
    var initialPage =
        storedPosition?.kind == MediaPositionKind.imageIndex &&
            storedPosition?.fileId == comics[chapterIndex].id
        ? ((storedPosition!.numericValue ?? 1).round() - 1).clamp(0, 1 << 30)
        : 0;
    var initialElementId = storedPosition?.fileId == comics[chapterIndex].id
        ? storedPosition?.elementId
        : null;
    var initialScrollOffset = storedPosition?.fileId == comics[chapterIndex].id
        ? storedPosition?.scrollOffset
        : null;
    Map<String, Object?>? portableProfile;
    var profileLoadedFromServer = false;
    if (!skipServerLookup) {
      try {
        portableProfile = await _client.readerProfile(
          server,
          libraryId: library.id,
          workId: work.id,
          deviceKey: Platform.operatingSystem,
          readerKind: 'comic',
        );
        profileLoadedFromServer = portableProfile != null;
      } catch (_) {}
    }
    portableProfile ??= offlineWork == null
        ? null
        : await _offlineStore.loadReaderProfile(
            serverId: server.id,
            libraryId: library.id,
            workId: work.id,
            deviceKey: Platform.operatingSystem,
            readerKind: 'comic',
          );
    if (profileLoadedFromServer && offlineWork != null) {
      await _offlineStore.saveReaderProfile(
        serverId: server.id,
        libraryId: library.id,
        workId: work.id,
        deviceKey: Platform.operatingSystem,
        readerKind: 'comic',
        profile: portableProfile!,
      );
    }
    var profile = portableProfile == null
        ? await PublicationReaderSettings.loadComicProfile(workId: work.id)
        : PublicationReaderProfile.fromJson(portableProfile);
    var profileDirty = false;
    var comicAnnotations = await _offlineStore.loadAnnotations(
      serverId: server.id,
      libraryId: library.id,
      workId: work.id,
    );
    final syncAnnotations = await AnnotationSyncSettings.enabled();
    if (!skipServerLookup && syncAnnotations) {
      try {
        final loaded = await _runWithReconnect(
          server,
          (active) => _client.annotations(active, library.id, work.id),
        );
        server = loaded.server;
        comicAnnotations = _mergeAnnotations(
          work,
          comicAnnotations,
          loaded.value,
        );
        await _offlineStore.cacheAnnotations(
          serverId: server.id,
          libraryId: library.id,
          workId: work.id,
          annotations: comicAnnotations,
        );
      } catch (_) {}
    }
    if (selectedDeviceProgress && localPosition != null) {
      await _saveRemoteReaderProgress(
        server,
        library,
        work,
        comics[chapterIndex],
        localPosition,
        deviceId: deviceId,
        finished: localProgress?.finished ?? false,
      );
    } else if (serverPosition != null) {
      await _offlineStore.cacheProgress(
        serverId: server.id,
        libraryId: library.id,
        workId: work.id,
        progress: serverProgress!,
        replacePending: true,
      );
    }
    if (!mounted) return;

    while (mounted) {
      final track = comics[chapterIndex];
      final offlineTrack = offlineWork?.tracks
          .where((candidate) => candidate.id == track.id)
          .firstOrNull;
      final ComicPageSource pageSource = offlineTrack != null
          ? ArchiveComicPageSource(
              offlineTrack.path,
              kind: PublicationSourceKind.offline,
              name: track.title,
            )
          : HttpComicPageSource(
              name: track.title,
              loadManifest: () async {
                final loaded = await _runWithReconnect(
                  server,
                  (active) => _client.comicPages(
                    active,
                    libraryId: library.id,
                    fileId: track.id,
                  ),
                );
                server = loaded.server;
                return loaded.value;
              },
              loadPage: (pageIndex) async {
                final loaded = await _runWithReconnect(
                  server,
                  (active) => _client.comicPage(
                    active,
                    libraryId: library.id,
                    fileId: track.id,
                    pageIndex: pageIndex,
                  ),
                );
                server = loaded.server;
                return loaded.value;
              },
            );
      final result = await showComicBookViewer(
        context,
        pageSource: pageSource,
        initialPage: initialPage,
        initialElementId: initialElementId,
        initialScrollOffset: initialScrollOffset,
        initialProfile: profile,
        hasPreviousChapter: chapterIndex > 0,
        hasNextChapter: chapterIndex + 1 < comics.length,
        chapterTitle: track.title,
        chapterIndex: chapterIndex,
        chapterCount: comics.length,
        chapterTitles: comics.map((chapter) => chapter.title).toList(),
        chapterFileId: track.id,
        initialBookmarks: comicAnnotations.bookmarks,
        initialNotes: comicAnnotations.notes,
        onAddBookmark: (position, label) async {
          final local = await _offlineStore.addMediaBookmark(
            serverId: server.id,
            libraryId: library.id,
            workId: work.id,
            fileId: track.id,
            position: position,
            label: label,
          );
          comicAnnotations = local;
          if (!skipServerLookup && syncAnnotations) {
            try {
              final remote = await _client.saveBookmark(
                server,
                libraryId: library.id,
                workId: work.id,
                fileId: track.id,
                position: position,
                label: label,
              );
              comicAnnotations = _mergeAnnotations(work, local, remote);
              await _offlineStore.cacheAnnotations(
                serverId: server.id,
                libraryId: library.id,
                workId: work.id,
                annotations: comicAnnotations,
              );
            } catch (_) {}
          }
          return comicAnnotations;
        },
        onDeleteBookmark: (bookmarkId) async {
          final local = await _offlineStore.deleteAnnotation(
            serverId: server.id,
            libraryId: library.id,
            workId: work.id,
            annotationId: bookmarkId,
          );
          comicAnnotations = local;
          if (!skipServerLookup && syncAnnotations) {
            try {
              final remote = await _client.deleteAnnotation(
                server,
                libraryId: library.id,
                workId: work.id,
                annotationId: bookmarkId,
                highlight: false,
              );
              comicAnnotations = _mergeAnnotations(work, local, remote);
            } catch (_) {}
          }
          return comicAnnotations;
        },
        onSaveNote: (markdown) async {
          final local = await _offlineStore.saveWorkNote(
            serverId: server.id,
            libraryId: library.id,
            workId: work.id,
            markdown: markdown,
          );
          comicAnnotations = local;
          if (!skipServerLookup && syncAnnotations) {
            try {
              final remote = await _client.saveNote(
                server,
                libraryId: library.id,
                workId: work.id,
                markdown: markdown,
              );
              comicAnnotations = _mergeAnnotations(work, local, remote);
              await _offlineStore.cacheAnnotations(
                serverId: server.id,
                libraryId: library.id,
                workId: work.id,
                annotations: comicAnnotations,
              );
            } catch (_) {}
          }
          return comicAnnotations;
        },
        onProfileChanged: (updated) {
          profile = updated;
          profileDirty = true;
          unawaited(
            PublicationReaderSettings.saveComicProfile(
              updated,
              workId: work.id,
            ),
          );
        },
        onPositionChanged: (page, total, elementId, scrollOffset) {
          final mediaPosition = MediaPosition(
            kind: MediaPositionKind.imageIndex,
            numericValue: page + 1,
            total: total.toDouble(),
            fileId: track.id,
            chapterId: track.title,
            elementId: elementId,
            scrollOffset: scrollOffset,
            key: track.title,
            label:
                'Kapitel ${chapterIndex + 1}/${comics.length} · Seite ${page + 1}',
          );
          _readerProgressQueue = _readerProgressQueue.then(
            (_) => _saveRemoteReaderProgress(
              server,
              library,
              work,
              track,
              mediaPosition,
              deviceId: deviceId,
              finished: chapterIndex + 1 == comics.length && page + 1 >= total,
              syncRemote: !skipServerLookup,
            ),
          );
        },
      );
      if (profileDirty) {
        await PublicationReaderSettings.saveComicProfile(
          profile,
          workId: work.id,
        );
        if (offlineWork != null) {
          await _offlineStore.saveReaderProfile(
            serverId: server.id,
            libraryId: library.id,
            workId: work.id,
            deviceKey: Platform.operatingSystem,
            readerKind: 'comic',
            profile: profile.toJson(),
          );
        }
        if (!skipServerLookup) {
          try {
            final saved = await _runWithReconnect(
              server,
              (active) => _client.saveReaderProfile(
                active,
                libraryId: library.id,
                workId: work.id,
                deviceKey: Platform.operatingSystem,
                readerKind: 'comic',
                profile: profile.toJson(),
              ),
            );
            server = saved.server;
          } catch (_) {
            // The local profile remains available for a later online save.
          }
        }
        profileDirty = false;
      }
      await _readerProgressQueue;
      if (!mounted || result == null) return;
      if (result.action == ComicBookViewerAction.selectChapter &&
          result.chapterIndex != null &&
          result.chapterIndex! >= 0 &&
          result.chapterIndex! < comics.length) {
        chapterIndex = result.chapterIndex!;
      } else if (result.action == ComicBookViewerAction.previousChapter &&
          chapterIndex > 0) {
        chapterIndex--;
      } else if (result.action == ComicBookViewerAction.nextChapter &&
          chapterIndex + 1 < comics.length) {
        chapterIndex++;
      } else {
        return;
      }
      initialPage = 0;
      initialElementId = null;
      initialScrollOffset = null;
    }
  }

  Future<void> _saveRemoteReaderProgress(
    FundusRemoteServer server,
    FundusRemoteLibrary library,
    FundusRemoteWork work,
    FundusRemoteTrack track,
    MediaPosition position, {
    required String deviceId,
    required bool finished,
    bool syncRemote = true,
  }) async {
    try {
      final pending = await _offlineStore.saveMediaProgress(
        serverId: server.id,
        libraryId: library.id,
        workId: work.id,
        fileId: track.id,
        position: position,
        finished: finished,
      );
      if (!syncRemote) return;
      await _runWithReconnect(
        server,
        (active) => _client.saveMediaProgress(
          active,
          libraryId: library.id,
          workId: work.id,
          fileId: track.id,
          position: position,
          finished: finished,
          deviceId: deviceId,
          operationId: pending.operationId,
        ),
      );
      await _offlineStore.markProgressSynced(pending);
    } catch (_) {
      // Offline progress remains queued locally and is retried later. A cache
      // write error must not break the serialized queue for later positions.
    }
  }

  Future<MediaPosition?> _showRemoteReaderProgressHistory(
    FundusRemoteServer server,
    FundusRemoteLibrary library,
    FundusRemoteWork work,
    List<FundusRemoteTrack> tracks,
  ) async {
    final deviceId = await _store.deviceId();
    if (!mounted) return null;
    final restored = await showReaderProgressHistory(
      context,
      loadHistory: () async {
        final loaded = await _runWithReconnect(
          server,
          (active) => _client.progressRevisions(active, library.id, work.id),
        );
        server = loaded.server;
        return [
          for (final revision in loaded.value)
            ReaderProgressRevisionView(
              revision: revision.revision,
              position: revision.mediaPosition,
              deviceId: revision.deviceId,
              deviceName: revision.deviceName,
              createdAt: revision.createdAt,
              fileTitle:
                  tracks
                      .where((track) => track.id == revision.fileId)
                      .firstOrNull
                      ?.title ??
                  'Gespeicherte Datei',
            ),
        ];
      },
      restoreRevision: (revision) async {
        final operationId =
            'reader-restore-${revision.revision}-'
            '${DateTime.now().microsecondsSinceEpoch}';
        final restored = await _runWithReconnect(
          server,
          (active) => _client.restoreProgressRevision(
            active,
            libraryId: library.id,
            workId: work.id,
            revision: revision.revision,
            deviceId: deviceId,
            operationId: operationId,
          ),
        );
        server = restored.server;
        await _offlineStore.cacheProgress(
          serverId: server.id,
          libraryId: library.id,
          workId: work.id,
          progress: restored.value,
          replacePending: true,
        );
      },
    );
    return restored?.position;
  }

  Future<void> _openRemotePdfWork(
    FundusRemoteServer server,
    FundusRemoteLibrary library,
    FundusRemoteWork work,
    List<FundusRemoteTrack> tracks, {
    required FundusOfflineWork? offlineWork,
    String? startFileId,
    bool skipServerLookup = false,
  }) async {
    final pdfs =
        tracks
            .where((track) => track.title.toLowerCase().endsWith('.pdf'))
            .toList(growable: false)
          ..sort((left, right) => left.position.compareTo(right.position));
    if (pdfs.isEmpty) return;

    final localProgress = await _offlineStore.loadProgress(
      serverId: server.id,
      libraryId: library.id,
      workId: work.id,
    );
    FundusRemoteProgress? serverProgress;
    if (!skipServerLookup) {
      try {
        final result = await _runWithReconnect(
          server,
          (active) => _client.progress(active, library.id, work.id),
        );
        server = result.server;
        serverProgress = result.value;
      } catch (_) {}
    }

    final localPosition = localProgress?.mediaPosition;
    final serverPosition = serverProgress?.mediaPosition;
    var selectedPosition = serverPosition ?? localPosition;
    var selectedFinished =
        serverProgress?.finished ?? localProgress?.finished ?? false;
    var selectedDeviceProgress = false;
    if (startFileId == null &&
        shouldResolveReaderProgressConflict(
          localPendingSync: localProgress?.pendingSync ?? false,
          devicePosition: localPosition,
          serverPosition: serverPosition,
        )) {
      final localDeviceName = await _store.deviceName();
      if (!mounted) return;
      final choice = await resolveReaderProgressConflict(
        context,
        devicePosition: localPosition!,
        serverPosition: serverPosition!,
        deviceName: localDeviceName,
        serverDeviceName: serverProgress?.deviceName ?? server.name,
      );
      selectedDeviceProgress =
          choice == ReaderProgressConflictChoice.keepDevice;
      selectedPosition = selectedDeviceProgress
          ? localPosition
          : serverPosition;
      selectedFinished = selectedDeviceProgress
          ? localProgress?.finished ?? false
          : serverProgress?.finished ?? false;
    }

    final targetFileId = startFileId ?? selectedPosition?.fileId;
    var fileIndex = pdfs.indexWhere((track) => track.id == targetFileId);
    if (fileIndex < 0) fileIndex = 0;
    final track = pdfs[fileIndex];
    final deviceId = await _store.deviceId();
    if (selectedDeviceProgress && selectedPosition != null) {
      await _saveRemoteReaderProgress(
        server,
        library,
        work,
        track,
        selectedPosition,
        deviceId: deviceId,
        finished: selectedFinished,
      );
    } else if (serverPosition != null) {
      await _offlineStore.cacheProgress(
        serverId: server.id,
        libraryId: library.id,
        workId: work.id,
        progress: serverProgress!,
        replacePending: true,
      );
    }

    final offlineTrack = offlineWork?.tracks
        .where((candidate) => candidate.id == track.id)
        .firstOrNull;
    final FixedDocumentSource source = offlineTrack == null
        ? MaterializedFixedDocumentSource(
            name: track.title,
            kind: PublicationSourceKind.remote,
            materialize: () async =>
                (await _cachedRemoteDocument(server, library, track)).path,
          )
        : FileFixedDocumentSource(
            offlineTrack.path,
            name: track.title,
            kind: PublicationSourceKind.offline,
          );
    final initialPage =
        selectedPosition?.kind == MediaPositionKind.page &&
            selectedPosition?.fileId == track.id &&
            startFileId == null
        ? ((selectedPosition!.numericValue ?? 1).round() - 1).clamp(0, 1 << 30)
        : 0;
    if (!mounted) return;
    try {
      await showDocumentPreview(
        context,
        source: source,
        initialPage: initialPage,
        onOpenExternal: (path) => const DocumentFileOpener().open(path),
        onPageChanged: (page, total) {
          final position = MediaPosition(
            kind: MediaPositionKind.page,
            numericValue: page + 1,
            total: total.toDouble(),
            fileId: track.id,
            key: track.title,
            label: 'Seite ${page + 1}',
          );
          _readerProgressQueue = _readerProgressQueue.then(
            (_) => _saveRemoteReaderProgress(
              server,
              library,
              work,
              track,
              position,
              deviceId: deviceId,
              finished: page + 1 >= total,
              syncRemote: !skipServerLookup,
            ),
          );
        },
      );
      await _readerProgressQueue;
    } on DocumentPreviewException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.message)));
    }
  }

  Future<void> _openRemoteEpubWork(
    FundusRemoteServer server,
    FundusRemoteLibrary library,
    FundusRemoteWork work,
    List<FundusRemoteTrack> tracks, {
    required FundusOfflineWork? offlineWork,
    String? startFileId,
    MediaPosition? startPosition,
    int? initialChapterIndex,
    bool skipServerLookup = false,
  }) async {
    final epubs =
        tracks
            .where((track) => track.title.toLowerCase().endsWith('.epub'))
            .toList(growable: false)
          ..sort((left, right) => left.position.compareTo(right.position));
    if (epubs.isEmpty) return;
    final localProgress = await _offlineStore.loadProgress(
      serverId: server.id,
      libraryId: library.id,
      workId: work.id,
    );
    FundusRemoteProgress? serverProgress;
    if (!skipServerLookup) {
      try {
        final result = await _runWithReconnect(
          server,
          (active) => _client.progress(active, library.id, work.id),
        );
        server = result.server;
        serverProgress = result.value;
      } catch (_) {}
    }
    final localPosition = localProgress?.mediaPosition;
    final serverPosition = serverProgress?.mediaPosition;
    var selectedPosition = startPosition ?? serverPosition ?? localPosition;
    var selectedDeviceProgress = false;
    if (startPosition == null &&
        startFileId == null &&
        shouldResolveReaderProgressConflict(
          localPendingSync: localProgress?.pendingSync ?? false,
          devicePosition: localPosition,
          serverPosition: serverPosition,
        )) {
      final deviceName = await _store.deviceName();
      if (!mounted) return;
      final choice = await resolveReaderProgressConflict(
        context,
        devicePosition: localPosition!,
        serverPosition: serverPosition!,
        deviceName: deviceName,
        serverDeviceName: serverProgress?.deviceName ?? server.name,
      );
      selectedPosition = choice == ReaderProgressConflictChoice.keepDevice
          ? localPosition
          : serverPosition;
      selectedDeviceProgress =
          choice == ReaderProgressConflictChoice.keepDevice;
    }
    if (startPosition == null &&
        startFileId == null &&
        serverProgress != null &&
        !selectedDeviceProgress) {
      await _offlineStore.cacheProgress(
        serverId: server.id,
        libraryId: library.id,
        workId: work.id,
        progress: serverProgress,
        replacePending: true,
      );
    }
    final targetFileId = startFileId ?? selectedPosition?.fileId;
    var fileIndex = epubs.indexWhere((track) => track.id == targetFileId);
    if (fileIndex < 0) fileIndex = 0;
    final track = epubs[fileIndex];
    final offlineTrack = offlineWork?.tracks
        .where((candidate) => candidate.id == track.id)
        .firstOrNull;
    final File file;
    try {
      file = offlineTrack == null
          ? await _cachedRemoteDocument(server, library, track)
          : File(offlineTrack.path);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('EPUB konnte nicht geladen werden.')),
      );
      return;
    }
    var annotations = await _offlineStore.loadAnnotations(
      serverId: server.id,
      libraryId: library.id,
      workId: work.id,
    );
    final syncAnnotations =
        !skipServerLookup && await AnnotationSyncSettings.enabled();
    Map<String, Object?>? portableProfile;
    var profileLoadedFromServer = false;
    if (!skipServerLookup) {
      try {
        portableProfile = await _client.readerProfile(
          server,
          libraryId: library.id,
          workId: work.id,
          deviceKey: Platform.operatingSystem,
          readerKind: 'epub',
        );
        profileLoadedFromServer = portableProfile != null;
      } catch (_) {}
    }
    portableProfile ??= offlineWork == null
        ? null
        : await _offlineStore.loadReaderProfile(
            serverId: server.id,
            libraryId: library.id,
            workId: work.id,
            deviceKey: Platform.operatingSystem,
            readerKind: 'epub',
          );
    if (profileLoadedFromServer && offlineWork != null) {
      await _offlineStore.saveReaderProfile(
        serverId: server.id,
        libraryId: library.id,
        workId: work.id,
        deviceKey: Platform.operatingSystem,
        readerKind: 'epub',
        profile: portableProfile!,
      );
    }
    var profile = portableProfile == null
        ? await PublicationReaderSettings.loadReflowProfile(workId: work.id)
        : ReflowReaderProfile.fromJson(portableProfile);
    var profileDirty = false;
    final deviceId = await _store.deviceId();
    if (selectedDeviceProgress && selectedPosition != null) {
      await _saveRemoteReaderProgress(
        server,
        library,
        work,
        track,
        selectedPosition,
        deviceId: deviceId,
        finished: localProgress?.finished ?? false,
      );
    }
    if (!mounted) return;
    try {
      await showEpubReader(
        context,
        source: FilePublicationSource(
          file.path,
          kind: offlineTrack == null
              ? PublicationSourceKind.remote
              : PublicationSourceKind.offline,
          name: track.title,
        ),
        fileId: track.id,
        relativePath: track.title,
        initialChapterIndex: initialChapterIndex,
        initialPosition:
            initialChapterIndex == null &&
                selectedPosition?.kind == MediaPositionKind.epubCfi &&
                selectedPosition?.fileId == track.id
            ? selectedPosition
            : null,
        initialProfile: profile,
        onProfileChanged: (updated) {
          profile = updated;
          profileDirty = true;
          unawaited(
            PublicationReaderSettings.saveReflowProfile(
              updated,
              workId: work.id,
            ),
          );
        },
        onSaveAsDefault: PublicationReaderSettings.saveReflowProfile,
        onResetWorkProfile: () =>
            PublicationReaderSettings.clearReflowProfile(work.id),
        initialBookmarks: annotations.bookmarks,
        initialHighlights: annotations.highlights,
        onAddBookmark: (position, label) async {
          final local = await _offlineStore.addMediaBookmark(
            serverId: server.id,
            libraryId: library.id,
            workId: work.id,
            fileId: track.id,
            position: position,
            label: label,
          );
          annotations = local;
          if (syncAnnotations) {
            try {
              final remote = await _client.saveBookmark(
                server,
                libraryId: library.id,
                workId: work.id,
                fileId: track.id,
                position: position,
                label: label,
              );
              annotations = _mergeAnnotations(work, local, remote);
              await _offlineStore.cacheAnnotations(
                serverId: server.id,
                libraryId: library.id,
                workId: work.id,
                annotations: annotations,
              );
            } catch (_) {}
          }
          return annotations;
        },
        onAddHighlight: (position, quote, color, note) async {
          final local = await _offlineStore.addTextHighlight(
            serverId: server.id,
            libraryId: library.id,
            workId: work.id,
            fileId: track.id,
            position: position,
            quote: quote,
            color: color,
            note: note,
          );
          annotations = local;
          if (syncAnnotations) {
            try {
              final remote = await _client.saveHighlight(
                server,
                libraryId: library.id,
                workId: work.id,
                fileId: track.id,
                position: position,
                quote: quote,
                color: color,
                note: note,
              );
              annotations = _mergeAnnotations(work, local, remote);
              await _offlineStore.cacheAnnotations(
                serverId: server.id,
                libraryId: library.id,
                workId: work.id,
                annotations: annotations,
              );
            } catch (_) {}
          }
          return annotations;
        },
        onDeleteBookmark: (id) async {
          final local = await _offlineStore.deleteAnnotation(
            serverId: server.id,
            libraryId: library.id,
            workId: work.id,
            annotationId: id,
          );
          annotations = local;
          if (syncAnnotations) {
            try {
              final remote = await _client.deleteAnnotation(
                server,
                libraryId: library.id,
                workId: work.id,
                annotationId: id,
                highlight: false,
              );
              annotations = _mergeAnnotations(work, local, remote);
              await _offlineStore.cacheAnnotations(
                serverId: server.id,
                libraryId: library.id,
                workId: work.id,
                annotations: annotations,
              );
            } catch (_) {}
          }
          return annotations;
        },
        onDeleteHighlight: (id) async {
          final local = await _offlineStore.deleteAnnotation(
            serverId: server.id,
            libraryId: library.id,
            workId: work.id,
            annotationId: id,
          );
          annotations = local;
          if (syncAnnotations) {
            try {
              final remote = await _client.deleteAnnotation(
                server,
                libraryId: library.id,
                workId: work.id,
                annotationId: id,
                highlight: true,
              );
              annotations = _mergeAnnotations(work, local, remote);
              await _offlineStore.cacheAnnotations(
                serverId: server.id,
                libraryId: library.id,
                workId: work.id,
                annotations: annotations,
              );
            } catch (_) {}
          }
          return annotations;
        },
        onExportAnnotations: () => _exportRemoteAnnotations(work, annotations),
        onPositionChanged: (position) {
          _readerProgressQueue = _readerProgressQueue.then(
            (_) => _saveRemoteReaderProgress(
              server,
              library,
              work,
              track,
              position,
              deviceId: deviceId,
              finished: (position.fraction ?? 0) >= .999,
              syncRemote: !skipServerLookup,
            ),
          );
        },
      );
      if (profileDirty) {
        await PublicationReaderSettings.saveReflowProfile(
          profile,
          workId: work.id,
        );
        if (offlineWork != null) {
          await _offlineStore.saveReaderProfile(
            serverId: server.id,
            libraryId: library.id,
            workId: work.id,
            deviceKey: Platform.operatingSystem,
            readerKind: 'epub',
            profile: profile.toJson(),
          );
        }
        if (!skipServerLookup) {
          try {
            final saved = await _runWithReconnect(
              server,
              (active) => _client.saveReaderProfile(
                active,
                libraryId: library.id,
                workId: work.id,
                deviceKey: Platform.operatingSystem,
                readerKind: 'epub',
                profile: profile.toJson(),
              ),
            );
            server = saved.server;
          } catch (_) {
            // The local profile remains available for a later online save.
          }
        }
      }
      await _readerProgressQueue;
    } on EpubPackageException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.message)));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('EPUB konnte nicht geöffnet werden: $error')),
      );
    }
  }

  Future<void> _exportRemoteAnnotations(
    FundusRemoteWork work,
    WorkAnnotations annotations,
  ) async {
    final format = await showDialog<String>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('Annotationen exportieren'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(dialogContext, 'md'),
            child: const ListTile(
              leading: Icon(Icons.description_outlined),
              title: Text('Markdown'),
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(dialogContext, 'json'),
            child: const ListTile(
              leading: Icon(Icons.data_object),
              title: Text('JSON'),
            ),
          ),
        ],
      ),
    );
    if (format == null) return;
    final safeTitle = work.title.replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_');
    final destination = await FilePicker.saveFile(
      dialogTitle: 'Fundus-Annotationen exportieren',
      fileName: '${safeTitle}_annotationen.$format',
      type: FileType.custom,
      allowedExtensions: [format],
    );
    if (destination == null) return;
    final contents = format == 'json'
        ? exportAnnotationsAsJson(
            workId: work.id,
            workTitle: work.title,
            annotations: annotations,
          )
        : exportAnnotationsAsMarkdown(
            workTitle: work.title,
            annotations: annotations,
          );
    await File(destination).writeAsString(contents, flush: true);
  }

  Future<void> _openDocumentPath(String path) async {
    try {
      if (path.toLowerCase().endsWith('.cbz')) {
        await showComicBookViewer(
          context,
          pageSource: ArchiveComicPageSource(path),
        );
      } else if (supportsInternalEpubReader(path)) {
        final profile = await PublicationReaderSettings.loadReflowProfile();
        if (!mounted) return;
        await showEpubReader(
          context,
          path: path,
          initialProfile: profile,
          onProfileChanged: (updated) =>
              unawaited(PublicationReaderSettings.saveReflowProfile(updated)),
          onSaveAsDefault: PublicationReaderSettings.saveReflowProfile,
        );
      } else if (supportsInternalReflowTextReader(path)) {
        final profile = await PublicationReaderSettings.loadReflowProfile();
        if (!mounted) return;
        await showReflowTextReader(
          context,
          path: path,
          title: path.split(Platform.pathSeparator).last,
          initialProfile: profile,
          onProfileChanged: (updated) =>
              unawaited(PublicationReaderSettings.saveReflowProfile(updated)),
          onSaveAsDefault: PublicationReaderSettings.saveReflowProfile,
        );
      } else if (path.toLowerCase().endsWith('.zip')) {
        await showZipArchiveBrowser(
          context,
          archivePath: path,
          onOpenExtracted: _openDocumentPath,
        );
      } else if (supportsInternalDocumentPreview(path)) {
        await showDocumentPreview(
          context,
          source: FileFixedDocumentSource(path),
          onOpenExternal: (value) => const DocumentFileOpener().open(value),
        );
      } else {
        await const DocumentFileOpener().open(path);
      }
    } on DocumentPreviewException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.message)));
    } on EpubPackageException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.message)));
    } on ReflowTextReaderException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.message)));
    } on DocumentOpenException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.message)));
    } on ZipArchiveException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.message)));
    }
  }

  static String _offlineSubtitle(FundusOfflineWork work) {
    final values = <String>[
      if (work.authors.isNotEmpty) work.authors.join(', '),
      if (work.series != null) work.series!,
      '${work.sourceServerName ?? work.serverId} / '
          '${work.sourceLibraryName ?? work.libraryId}',
    ];
    return values.join(' · ');
  }

  static String _formatRemoteSequence(num value) =>
      value == value.roundToDouble()
      ? value.toInt().toString()
      : value.toString().replaceAll('.', ',');

  static String _remoteLanguage(String value) {
    final normalized = value.toLowerCase().replaceAll('_', '-');
    return switch (normalized.split('-').first) {
      'de' || 'deu' || 'ger' => 'Deutsch',
      'en' || 'eng' => 'Englisch',
      'fr' || 'fra' || 'fre' => 'Französisch',
      'es' || 'spa' => 'Spanisch',
      'it' || 'ita' => 'Italienisch',
      'ja' || 'jpn' => 'Japanisch',
      _ => value,
    };
  }

  static List<VideoProviderCredit> _remoteVideoCredits(
    Map<String, Object?> providerMetadata,
  ) => (providerMetadata['credits'] as List? ?? const [])
      .map(VideoProviderCredit.fromJson)
      .whereType<VideoProviderCredit>()
      .take(12)
      .toList(growable: false);

  static String? _remoteTrailerUrl(Map<String, Object?> providerMetadata) {
    final value = providerMetadata['trailer_url'];
    final url = value is String ? value.trim() : '';
    return url.isEmpty ? null : url;
  }

  static Widget _remoteCreditAvatar(VideoProviderCredit credit) {
    final imageUrl = credit.imageUrl?.trim();
    if (imageUrl == null || imageUrl.isEmpty) {
      return const Icon(Icons.person_outline, size: 16);
    }
    return CircleAvatar(
      radius: 12,
      backgroundImage: NetworkImage(imageUrl),
      onBackgroundImageError: (_, _) {},
      child: const SizedBox.shrink(),
    );
  }

  static Future<void> _copyRemoteTrailer(
    BuildContext context,
    String url,
  ) async {
    await Clipboard.setData(ClipboardData(text: url));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Trailer-Link in die Zwischenablage kopiert.'),
      ),
    );
  }

  Future<void> _showOfflineWork(FundusOfflineWork offline) async {
    final isDocument = _isDocumentKind(offline.kind);
    if (isDocument) {
      final storedServer = _servers
          .where((item) => item.id == offline.serverId)
          .firstOrNull;
      FundusRemoteServer? onlineServer;
      if (storedServer != null) {
        try {
          final result = await _runWithReconnect(
            storedServer,
            (active) => _client.libraries(active),
          );
          onlineServer = result.server;
          _heartbeatServer = onlineServer;
        } catch (_) {
          // Die heruntergeladene Kopie bleibt vollständig offline lesbar.
        }
      }
      final server =
          onlineServer ??
          storedServer ??
          FundusRemoteServer(
            id: offline.serverId,
            name: offline.sourceServerName ?? 'Offline',
            baseUri: Uri.parse('https://127.0.0.1'),
            certificateFingerprint: ''.padLeft(64, '0'),
            token: '',
          );
      final library = FundusRemoteLibrary(
        id: offline.libraryId,
        name: offline.sourceLibraryName ?? 'Offline-Bibliothek',
        workCount: 1,
      );
      final work = FundusRemoteWork(
        id: offline.workId,
        title: offline.title,
        authors: offline.authors,
        hasCover: offline.coverPath != null,
        kind: offline.kind,
        subtitle: offline.subtitle,
        series: offline.series,
        seriesSequence: offline.seriesSequence,
        narrators: offline.narrators,
        language: offline.language,
        description: offline.description,
        publisher: offline.publisher,
        publishedYear: offline.publishedYear,
        fileCount: offline.tracks.length,
        providerMetadata: offline.providerMetadata,
        contentSensitivity: offline.contentSensitivity,
        contentStyle: offline.contentStyle,
      );
      await _showWork(
        server,
        library,
        work,
        forceOffline: onlineServer == null,
      );
      return;
    }
    final progress = await _offlineStore.loadProgress(
      serverId: offline.serverId,
      libraryId: offline.libraryId,
      workId: offline.workId,
    );
    if (!mounted) return;
    final action = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 120,
                    height: 170,
                    child: offline.coverPath == null
                        ? const Icon(Icons.audiotrack, size: 72)
                        : ClipRRect(
                            borderRadius: BorderRadius.circular(10),
                            child: Image.file(
                              File(offline.coverPath!),
                              fit: BoxFit.cover,
                            ),
                          ),
                  ),
                  const SizedBox(width: 18),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          offline.title,
                          style: Theme.of(context).textTheme.headlineSmall,
                        ),
                        if (offline.subtitle case final subtitle?) ...[
                          const SizedBox(height: 4),
                          Text(subtitle),
                        ],
                        if (offline.authors.isNotEmpty) ...[
                          const SizedBox(height: 6),
                          Text(offline.authors.join(', ')),
                        ],
                        if (offline.series case final series?) ...[
                          const SizedBox(height: 6),
                          Text(
                            offline.seriesSequence == null
                                ? series
                                : '$series · Band '
                                      '${_formatRemoteSequence(offline.seriesSequence!)}',
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.dns_outlined),
                title: Text(offline.sourceServerName ?? offline.serverId),
                subtitle: Text(
                  'Quellbibliothek: '
                  '${offline.sourceLibraryName ?? offline.libraryId}',
                ),
              ),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final narrator in offline.narrators)
                    Chip(
                      avatar: const Icon(Icons.mic_none, size: 16),
                      label: Text(narrator),
                    ),
                  if (offline.language case final language?)
                    Chip(label: Text(_remoteLanguage(language))),
                  if (offline.publisher case final publisher?)
                    Chip(
                      label: Text(
                        offline.publishedYear == null
                            ? publisher
                            : '$publisher · ${offline.publishedYear}',
                      ),
                    )
                  else if (offline.publishedYear case final year?)
                    Chip(label: Text('$year')),
                  Chip(label: Text('${offline.tracks.length} Datei(en)')),
                  const Chip(
                    avatar: Icon(Icons.download_done, size: 16),
                    label: Text('Offline'),
                  ),
                  if (offline.incomplete)
                    Chip(
                      avatar: const Icon(Icons.warning_amber_rounded, size: 16),
                      label: Text(
                        '${offline.missingTrackTitles.length} Datei(en) fehlen',
                      ),
                    ),
                ],
              ),
              if (_remoteVideoCredits(offline.providerMetadata).isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  'Besetzung & Crew',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final credit in _remoteVideoCredits(
                      offline.providerMetadata,
                    ))
                      Chip(
                        avatar: _remoteCreditAvatar(credit),
                        label: Text(
                          credit.role == null || credit.role!.trim().isEmpty
                              ? credit.name
                              : '${credit.name} · ${credit.role}',
                        ),
                      ),
                  ],
                ),
              ],
              if (_remoteTrailerUrl(offline.providerMetadata)
                  case final trailer?)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: TextButton.icon(
                    onPressed: () => _copyRemoteTrailer(context, trailer),
                    icon: const Icon(Icons.ondemand_video),
                    label: const Text('Trailer-Link kopieren'),
                  ),
                ),
              if (progress != null &&
                  !progress.finished &&
                  progress.position > Duration.zero) ...[
                const SizedBox(height: 14),
                Text(
                  'Fortsetzen bei ${_formatRemoteDuration(progress.position)}',
                  style: Theme.of(context).textTheme.labelLarge,
                ),
              ],
              if (isDocument) ...[
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: () => Navigator.pop(context, 'open:resume'),
                    icon: const Icon(Icons.menu_book_outlined),
                    label: Text(
                      progress?.mediaPosition == null ? 'Lesen' : 'Fortsetzen',
                    ),
                  ),
                ),
              ],
              if (offline.description case final description?) ...[
                const SizedBox(height: 20),
                Text(
                  'Beschreibung',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                SelectableText(description),
              ],
              const SizedBox(height: 20),
              Text(
                'Speicherort',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 6),
              SelectableText(offline.directoryPath),
              if (isDocument) ...[
                const SizedBox(height: 20),
                Text('Dateien', style: Theme.of(context).textTheme.titleMedium),
                for (var index = 0; index < offline.tracks.length; index++)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: documentChapterLeading(
                      context,
                      index + 1,
                      documentChapterReadState(
                        chapterIndex: index,
                        currentChapterIndex: offline.tracks.indexWhere(
                          (track) => track.id == progress?.fileId,
                        ),
                        workFinished: progress?.finished ?? false,
                        currentPosition: progress?.mediaPosition,
                      ),
                    ),
                    title: Text(
                      offline.tracks[index].title,
                      style: documentChapterTitleStyle(
                        context,
                        documentChapterReadState(
                          chapterIndex: index,
                          currentChapterIndex: offline.tracks.indexWhere(
                            (track) => track.id == progress?.fileId,
                          ),
                          workFinished: progress?.finished ?? false,
                          currentPosition: progress?.mediaPosition,
                        ),
                      ),
                    ),
                    trailing: const Icon(Icons.open_in_new),
                    onTap: () => Navigator.pop(context, 'open:$index'),
                  ),
              ],
              const SizedBox(height: 24),
              if (!isDocument)
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: () => Navigator.pop(context, 'play'),
                    icon: const Icon(Icons.play_arrow),
                    label: Text(
                      progress != null && progress.position > Duration.zero
                          ? 'Weiterhören'
                          : 'Abspielen',
                    ),
                  ),
                ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () => Navigator.pop(context, 'delete'),
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('Download löschen'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (action?.startsWith('open:') ?? false) {
      final target = action!.substring(5);
      final resume = target == 'resume';
      final progressFileId =
          progress?.fileId ?? progress?.mediaPosition?.fileId;
      final resumeIndex = offline.tracks.indexWhere(
        (track) => track.id == progressFileId,
      );
      final index = resume
          ? (resumeIndex < 0 ? 0 : resumeIndex)
          : int.tryParse(target);
      if (index != null && index >= 0 && index < offline.tracks.length) {
        final server =
            _servers.where((item) => item.id == offline.serverId).firstOrNull ??
            FundusRemoteServer(
              id: offline.serverId,
              name: 'Offline',
              baseUri: Uri.parse('https://127.0.0.1'),
              certificateFingerprint: ''.padLeft(64, '0'),
              token: '',
            );
        final library = FundusRemoteLibrary(
          id: offline.libraryId,
          name: 'Offline',
          workCount: 1,
        );
        final work = FundusRemoteWork(
          id: offline.workId,
          title: offline.title,
          authors: offline.authors,
          hasCover: offline.coverPath != null,
          kind: offline.kind,
          subtitle: offline.subtitle,
          series: offline.series,
          seriesSequence: offline.seriesSequence,
          narrators: offline.narrators,
          language: offline.language,
          description: offline.description,
          publisher: offline.publisher,
          publishedYear: offline.publishedYear,
          fileCount: offline.tracks.length,
          contentSensitivity: offline.contentSensitivity,
          contentStyle: offline.contentStyle,
        );
        final tracks = [
          for (final track in offline.tracks)
            FundusRemoteTrack(
              id: track.id,
              title: track.title,
              position: track.position,
              duration: track.duration,
              audioMetadata: track.audioMetadata,
            ),
        ];
        final selected = offline.tracks[index];
        if (selected.title.toLowerCase().endsWith('.cbz')) {
          await _openRemoteComicWork(
            server,
            library,
            work,
            tracks,
            offlineWork: offline,
            startFileId: resume ? null : selected.id,
            skipServerLookup: true,
          );
        } else if (selected.title.toLowerCase().endsWith('.pdf')) {
          await _openRemotePdfWork(
            server,
            library,
            work,
            tracks,
            offlineWork: offline,
            startFileId: resume ? null : selected.id,
            skipServerLookup: true,
          );
        } else if (selected.title.toLowerCase().endsWith('.epub')) {
          await _openRemoteEpubWork(
            server,
            library,
            work,
            tracks,
            offlineWork: offline,
            startFileId: resume ? null : selected.id,
            skipServerLookup: true,
          );
        } else {
          await _openDocumentPath(selected.path);
        }
      }
    } else if (action == 'play') {
      await _playOffline(offline);
    } else if (action == 'delete' && mounted) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Offline-Download löschen?'),
          content: Text(
            '„${offline.title}“ wird nur von diesem Gerät entfernt.',
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
      if (confirmed != true) return;
      await _offlineStore.remove(
        serverId: offline.serverId,
        libraryId: offline.libraryId,
        workId: offline.workId,
      );
      if (!mounted) return;
      setState(() {
        _offlineWorks = _offlineWorks
            .where(
              (item) =>
                  item.serverId != offline.serverId ||
                  item.libraryId != offline.libraryId ||
                  item.workId != offline.workId,
            )
            .toList();
        _offlineKeys.remove(
          '${offline.serverId}/${offline.libraryId}/${offline.workId}',
        );
      });
    }
  }

  Future<void> _playOffline(FundusOfflineWork offline) async {
    final server =
        _servers.where((item) => item.id == offline.serverId).firstOrNull ??
        FundusRemoteServer(
          id: offline.serverId,
          name: 'Offline',
          baseUri: Uri.parse('https://127.0.0.1'),
          certificateFingerprint: ''.padLeft(64, '0'),
          token: '',
        );
    final library = FundusRemoteLibrary(
      id: offline.libraryId,
      name: 'Offline',
      workCount: 1,
    );
    final work = FundusRemoteWork(
      id: offline.workId,
      title: offline.title,
      authors: offline.authors,
      hasCover: offline.coverPath != null,
      kind: offline.kind,
      subtitle: offline.subtitle,
      series: offline.series,
      seriesSequence: offline.seriesSequence,
      narrators: offline.narrators,
      language: offline.language,
      description: offline.description,
      publisher: offline.publisher,
      publishedYear: offline.publishedYear,
      fileCount: offline.tracks.length,
      contentSensitivity: offline.contentSensitivity,
      contentStyle: offline.contentStyle,
    );
    final player =
        _remotePlayer ??
        FundusRemotePlayerController(
          deviceId: await _store.deviceId(),
          deviceName: await _store.deviceName(),
          offlineStore: _offlineStore,
          onConflict: (conflict) => resolvePlaybackConflict(context, conflict),
          serverResolver: _relocatePlayerServer,
        );
    if (_remotePlayer == null && mounted) {
      setState(() => _remotePlayer = player);
    }
    await player.open(server, library, work, offlineWork: offline);
  }
}

class _MobileRemotePublicationDetails extends StatefulWidget {
  const _MobileRemotePublicationDetails({
    required this.work,
    required this.detail,
    required this.tracks,
    required this.relatedWorks,
    required this.progressPosition,
    required this.progressIndex,
    required this.annotations,
    required this.isOffline,
    required this.progressHistoryAvailable,
    required this.epubPublicationLoader,
    required this.onSaveNote,
    required this.onSaveTags,
    required this.coverBuilder,
  });

  final FundusRemoteWork work;
  final WorkDetailViewModel detail;
  final List<FundusRemoteTrack> tracks;
  final List<FundusRemoteWork> relatedWorks;
  final MediaPosition? progressPosition;
  final int progressIndex;
  final WorkAnnotations annotations;
  final bool isOffline;
  final bool progressHistoryAvailable;
  final Future<EpubPublication> Function()? epubPublicationLoader;
  final Future<WorkAnnotations> Function(String markdown) onSaveNote;
  final Future<WorkAnnotations> Function(Set<String> tags) onSaveTags;
  final Widget Function() coverBuilder;

  @override
  State<_MobileRemotePublicationDetails> createState() =>
      _MobileRemotePublicationDetailsState();
}

class _MobileRemotePublicationDetailsState
    extends State<_MobileRemotePublicationDetails> {
  final _noteController = TextEditingController();
  var _tab = WorkDetailSection.info;
  var _notesTab = WorkAnnotationSection.notes;
  var _sort = _DocumentTrackSort.oldestFirst;
  String _filter = '';
  late WorkAnnotations _annotations;
  bool _noteSaving = false;
  Future<EpubPublication>? _epubPublication;

  @override
  void initState() {
    super.initState();
    _annotations = widget.annotations;
  }

  @override
  void dispose() {
    _noteController.dispose();
    super.dispose();
  }

  List<({FundusRemoteTrack track, int originalIndex})> get _tracks =>
      _orderedRemoteTracks(widget.tracks, _sort)
          .where(
            (entry) =>
                entry.track.title.toLowerCase().contains(_filter.toLowerCase()),
          )
          .toList(growable: false);

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(widget.detail.summary.title, overflow: TextOverflow.ellipsis),
      actions: [
        if (widget.progressHistoryAvailable)
          IconButton(
            onPressed: () => Navigator.pop(context, 'progress_history'),
            tooltip: 'Gerätestände',
            icon: const Icon(Icons.history),
          ),
        IconButton(
          onPressed: _showFilterAndSort,
          tooltip: 'Filtern und sortieren',
          icon: const Icon(Icons.tune),
        ),
      ],
    ),
    body: SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
            child: Column(
              children: [
                WorkDetailHeader(
                  detail: widget.detail,
                  breadcrumbs: _remoteDetailBreadcrumbs(widget.detail),
                  coverBuilder: (_) => widget.coverBuilder(),
                  onCoverTap: _showCover,
                  favorite: _isFavorite,
                  onToggleFavorite: _toggleFavorite,
                  primaryAction: WorkDetailHeaderAction(
                    label: widget.progressPosition == null
                        ? 'Lesen'
                        : 'Fortsetzen',
                    icon: Icons.menu_book_outlined,
                    onPressed: () => Navigator.pop(context, 'open:resume'),
                  ),
                  secondaryAction: WorkDetailHeaderAction(
                    label: widget.isOffline
                        ? 'Kapitel verwalten'
                        : 'Zur Bibliothek',
                    icon: widget.isOffline
                        ? Icons.download_done
                        : Icons.download_outlined,
                    onPressed: () => Navigator.pop(context, 'download'),
                  ),
                ),
                const SizedBox(height: 12),
                WorkDetailSectionSelector(
                  selected: _tab,
                  onChanged: (value) => setState(() => _tab = value),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(child: _tabBody()),
        ],
      ),
    ),
  );

  Widget _tabBody() => switch (_tab) {
    WorkDetailSection.info => ListView(
      padding: const EdgeInsets.all(18),
      children: [
        if (widget.work.description case final description?) ...[
          Text(
            'Zusammenfassung',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          SelectableText(description),
          const SizedBox(height: 22),
        ],
        Text('Details', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        WorkDetailFacts(
          detail: widget.detail,
          progress: widget.progressPosition,
        ),
      ],
    ),
    WorkDetailSection.files => _trackList(_tracks),
    WorkDetailSection.chapters => _chapterList(),
    WorkDetailSection.notes => Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: WorkAnnotationSectionSelector(
            selected: _notesTab,
            onChanged: (value) => setState(() => _notesTab = value),
          ),
        ),
        Expanded(
          child: _notesTab == WorkAnnotationSection.notes
              ? _notesList()
              : _annotationList(),
        ),
      ],
    ),
    WorkDetailSection.similar => _similarList(),
    WorkDetailSection.devices => Center(
      child: FilledButton.icon(
        onPressed: widget.progressHistoryAvailable
            ? () => Navigator.pop(context, 'progress_history')
            : null,
        icon: const Icon(Icons.history),
        label: const Text('Gerätestände anzeigen'),
      ),
    ),
  };

  Widget _trackList(
    List<({FundusRemoteTrack track, int originalIndex})> entries,
  ) {
    final rows = <Widget>[];
    int? currentSeason;
    for (final entry in entries) {
      final episode =
          entry.track.episode ?? parseVideoEpisode(entry.track.title);
      if (episode != null &&
          _sort != _DocumentTrackSort.titleAscending &&
          episode.season != currentSeason) {
        currentSeason = episode.season;
        rows.add(
          ListTile(
            dense: true,
            leading: const Icon(Icons.video_library_outlined),
            title: Text(
              episode.season == 0
                  ? 'Specials / Staffel 00'
                  : 'Staffel ${episode.season}',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
        );
      }
      rows.add(
        WorkContentListTile(
          item: WorkContentItemViewModel(
            id: entry.track.id,
            title: _remoteTrackLabel(entry.track),
            number: episode?.episode ?? entry.originalIndex + 1,
            readState: documentChapterReadState(
              chapterIndex: entry.originalIndex,
              currentChapterIndex: widget.progressIndex,
              workFinished: widget.work.progressFinished,
              currentPosition: widget.progressPosition,
            ),
            availability: widget.isOffline
                ? WorkContentAvailability.offline
                : WorkContentAvailability.remote,
            subtitle: _remoteTechnicalSubtitle(entry.track),
          ),
          onTap: () => Navigator.pop(context, 'open:${entry.originalIndex}'),
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      children: rows,
    );
  }

  Widget _chapterList() {
    final loader = widget.epubPublicationLoader;
    if (loader == null) {
      return _trackList(
        _tracks
            .where((entry) {
              final title = entry.track.title.toLowerCase();
              return title.endsWith('.cbz') ||
                  title.endsWith('.pdf') ||
                  title.endsWith('.html') ||
                  title.endsWith('.htm') ||
                  title.endsWith('.md') ||
                  title.endsWith('.txt');
            })
            .toList(growable: false),
      );
    }
    _epubPublication ??= loader();
    return FutureBuilder<EpubPublication>(
      future: _epubPublication,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return const Center(
            child: Text(
              'Das EPUB-Inhaltsverzeichnis konnte nicht geladen werden.',
            ),
          );
        }
        final publication = snapshot.data;
        if (publication == null) {
          return const Center(child: CircularProgressIndicator());
        }
        final currentChapterIndex = publication.chapters.indexWhere(
          (chapter) =>
              chapter.id == widget.progressPosition?.chapterId ||
              chapter.title == widget.progressPosition?.chapterId,
        );
        return ListView.builder(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          itemCount: publication.chapters.length,
          itemBuilder: (context, index) {
            final chapter = publication.chapters[index];
            return WorkContentListTile(
              item: WorkContentItemViewModel(
                id: chapter.id,
                title: chapter.title,
                number: index + 1,
                readState: documentChapterReadState(
                  chapterIndex: index,
                  currentChapterIndex: currentChapterIndex,
                  workFinished: widget.work.progressFinished,
                  currentPosition: widget.progressPosition,
                ),
                availability: widget.isOffline
                    ? WorkContentAvailability.offline
                    : WorkContentAvailability.remote,
              ),
              contentPadding: EdgeInsets.only(
                left: 8.0 + chapter.depth * 16,
                right: 8,
              ),
              onTap: () => Navigator.pop(context, 'epub_chapter:$index'),
            );
          },
        );
      },
    );
  }

  Widget _annotationList() {
    return WorkAnnotationList(
      bookmarks: _annotations.bookmarks,
      highlights: _annotations.highlights,
      onOpenBookmark: (item) => Navigator.pop(context, 'annotation:${item.id}'),
      onOpenHighlight: (item) =>
          Navigator.pop(context, 'annotation:${item.id}'),
    );
  }

  bool get _isFavorite =>
      {...widget.work.tags, ..._annotations.tags}.contains('Favorit');

  Widget _notesList() => WorkNotesList(
    notes: _annotations.notes,
    composer: Column(
      children: [
        TextField(
          controller: _noteController,
          minLines: 3,
          maxLines: 8,
          decoration: const InputDecoration(
            hintText: 'Notiz in Markdown schreiben …',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 8),
        FilledButton.icon(
          onPressed: _noteSaving ? null : _saveNote,
          icon: _noteSaving
              ? const SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.save_outlined),
          label: const Text('Notiz speichern'),
        ),
      ],
    ),
  );

  Widget _similarList() {
    final sourceTags = {...widget.work.tags, ..._annotations.tags}
      ..remove('Favorit');
    final candidates = <({FundusRemoteWork work, int score})>[];
    for (final candidate in widget.relatedWorks) {
      if (candidate.id == widget.work.id ||
          candidate.kind != widget.work.kind) {
        continue;
      }
      final score = candidate.tags.where(sourceTags.contains).length;
      if (score > 0) candidates.add((work: candidate, score: score));
    }
    candidates.sort((left, right) {
      final score = right.score.compareTo(left.score);
      return score != 0 ? score : left.work.title.compareTo(right.work.title);
    });
    if (candidates.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('Noch keine Titel mit übereinstimmenden Tags.'),
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        for (final candidate in candidates)
          ListTile(
            leading: const Icon(Icons.auto_awesome_outlined),
            title: Text(candidate.work.title),
            subtitle: Text('${candidate.score} gemeinsame Tag(s)'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.pop(context, 'similar:${candidate.work.id}'),
          ),
      ],
    );
  }

  Future<void> _saveNote() async {
    final markdown = _noteController.text.trim();
    if (markdown.isEmpty) return;
    setState(() {
      _noteSaving = true;
      _annotations = WorkAnnotations(
        tags: _annotations.tags,
        note: markdown,
        notes: [
          ..._annotations.notes,
          LibraryNote(
            id: 'pending-${DateTime.now().microsecondsSinceEpoch}',
            markdown: markdown,
            createdAt: DateTime.now(),
          ),
        ],
        bookmarks: _annotations.bookmarks,
        highlights: _annotations.highlights,
      );
      _noteController.clear();
    });
    try {
      final updated = await widget.onSaveNote(markdown);
      if (!mounted) return;
      setState(() => _annotations = updated);
    } catch (error) {
      if (!mounted) return;
      _noteController.text = markdown;
      setState(() => _annotations = widget.annotations);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Notiz konnte nicht gespeichert werden: $error'),
        ),
      );
    } finally {
      if (mounted) setState(() => _noteSaving = false);
    }
  }

  Future<void> _toggleFavorite() async {
    final tags = {...widget.work.tags, ..._annotations.tags};
    tags.contains('Favorit') ? tags.remove('Favorit') : tags.add('Favorit');
    final updated = await widget.onSaveTags(tags);
    if (mounted) setState(() => _annotations = updated);
  }

  Future<void> _showCover() => showDialog<void>(
    context: context,
    builder: (context) => Dialog(
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520, maxHeight: 720),
        child: AspectRatio(aspectRatio: 2 / 3, child: widget.coverBuilder()),
      ),
    ),
  );

  Future<void> _showFilterAndSort() async {
    final controller = TextEditingController(text: _filter);
    var draftSort = _sort;
    final result =
        await showModalBottomSheet<({String filter, _DocumentTrackSort sort})>(
          context: context,
          showDragHandle: true,
          builder: (context) => StatefulBuilder(
            builder: (context, setSheetState) => Padding(
              padding: EdgeInsets.fromLTRB(
                20,
                0,
                20,
                20 + MediaQuery.viewInsetsOf(context).bottom,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: controller,
                    decoration: const InputDecoration(
                      labelText: 'Kapitel filtern',
                      prefixIcon: Icon(Icons.search),
                    ),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<_DocumentTrackSort>(
                    initialValue: draftSort,
                    decoration: const InputDecoration(labelText: 'Sortierung'),
                    items: const [
                      DropdownMenuItem(
                        value: _DocumentTrackSort.oldestFirst,
                        child: Text('Älteste zuerst'),
                      ),
                      DropdownMenuItem(
                        value: _DocumentTrackSort.newestFirst,
                        child: Text('Neueste zuerst'),
                      ),
                      DropdownMenuItem(
                        value: _DocumentTrackSort.seasonEpisode,
                        child: Text('Staffel/Folge'),
                      ),
                      DropdownMenuItem(
                        value: _DocumentTrackSort.titleAscending,
                        child: Text('Name A–Z'),
                      ),
                    ],
                    onChanged: (value) {
                      if (value != null) setSheetState(() => draftSort = value);
                    },
                  ),
                  const SizedBox(height: 18),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: () => Navigator.pop(context, (
                        filter: controller.text.trim(),
                        sort: draftSort,
                      )),
                      child: const Text('Anwenden'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
    controller.dispose();
    if (result != null && mounted) {
      setState(() {
        _filter = result.filter;
        _sort = result.sort;
      });
    }
  }
}

class _RemoteExpandedPlayer extends StatelessWidget {
  const _RemoteExpandedPlayer({required this.controller});

  final FundusRemotePlayerController controller;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, child) => Scaffold(
      appBar: AppBar(
        title: Text(controller.work?.title ?? 'Player'),
        actions: [
          IconButton(
            onPressed: () => Navigator.pop(context),
            tooltip: 'Player verkleinern',
            icon: const Icon(Icons.close_fullscreen),
          ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final coverPath = controller.offlineCoverPath;
          final cover = AspectRatio(
            aspectRatio: 1,
            child: coverPath == null
                ? const Card(child: Icon(Icons.audiotrack, size: 100))
                : ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: Image.file(File(coverPath), fit: BoxFit.cover),
                  ),
          );
          final details = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                controller.work?.title ?? 'Remote-Wiedergabe',
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              if (controller.work?.authors case final authors?)
                if (authors.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(authors.join(', ')),
                ],
              if (controller.work?.series case final series?) ...[
                const SizedBox(height: 8),
                Text(series),
              ],
              if (controller.work?.description case final description?) ...[
                const SizedBox(height: 20),
                Text(
                  'Beschreibung',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                Text(description, maxLines: 8, overflow: TextOverflow.ellipsis),
              ],
            ],
          );
          return ListView(
            padding: const EdgeInsets.all(20),
            children: [
              if (constraints.maxWidth >= 700)
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(width: 300, child: cover),
                    const SizedBox(width: 28),
                    Expanded(child: details),
                  ],
                )
              else ...[
                Center(child: SizedBox(width: 280, child: cover)),
                const SizedBox(height: 20),
                details,
              ],
              const SizedBox(height: 24),
              Text('Chapters', style: Theme.of(context).textTheme.titleMedium),
              if (controller.chapters.isEmpty)
                const ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text('Keine Chapters gefunden.'),
                )
              else
                for (var index = 0; index < controller.chapters.length; index++)
                  ListTile(
                    selected: index == controller.currentChapterIndex,
                    leading: Text('${index + 1}'),
                    title: Text(controller.chapters[index].title),
                    subtitle: Text(
                      _remoteChapterSubtitle(
                        controller.chapters[index],
                        controller.tracks.length,
                      ),
                    ),
                    trailing: index == controller.currentChapterIndex
                        ? const Icon(Icons.graphic_eq)
                        : null,
                    onTap: () =>
                        controller.jumpToChapter(controller.chapters[index]),
                  ),
              const SizedBox(height: 24),
              Text('Dateien', style: Theme.of(context).textTheme.titleMedium),
              for (var index = 0; index < controller.tracks.length; index++)
                ListTile(
                  selected: index == controller.currentIndex,
                  leading: Text('${index + 1}'),
                  title: Text(controller.tracks[index].title),
                  subtitle: _remoteTechnicalSubtitle(controller.tracks[index]),
                  trailing: index == controller.currentIndex
                      ? const Icon(Icons.graphic_eq)
                      : null,
                  onTap: index == controller.currentIndex
                      ? null
                      : () async {
                          final current = controller.track;
                          if (current == null ||
                              !await confirmPlaybackTrackJump(
                                context,
                                currentTitle: current.title,
                                targetTitle: controller.tracks[index].title,
                                currentPosition: controller.position,
                              )) {
                            return;
                          }
                          await controller.jumpToTrack(index);
                        },
                ),
              const SizedBox(height: 160),
            ],
          );
        },
      ),
      bottomNavigationBar: _RemotePlayerBar(controller: controller),
    ),
  );
}

class _RemotePlayerBar extends StatelessWidget {
  const _RemotePlayerBar({required this.controller, this.onExpand});

  final FundusRemotePlayerController controller;
  final VoidCallback? onExpand;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, child) {
      final maximum = controller.duration.inMilliseconds.toDouble();
      final position = controller.position.inMilliseconds
          .clamp(0, maximum > 0 ? maximum : 1)
          .toDouble();
      return Material(
        elevation: 12,
        color: Theme.of(context).colorScheme.surfaceContainer,
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (controller.loading) const LinearProgressIndicator(),
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            controller.work?.title ?? 'Remote-Wiedergabe',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                          Text(
                            controller.track?.title ?? 'Wird geladen …',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      onPressed: controller.previous,
                      icon: const Icon(Icons.skip_previous),
                    ),
                    IconButton(
                      onPressed: () =>
                          controller.seekRelative(const Duration(seconds: -15)),
                      tooltip: '15 Sekunden zurück',
                      icon: const Icon(Icons.replay_10),
                    ),
                    IconButton.filled(
                      onPressed: controller.loading
                          ? null
                          : controller.playOrPause,
                      icon: Icon(
                        controller.playing ? Icons.pause : Icons.play_arrow,
                      ),
                    ),
                    IconButton(
                      onPressed: () =>
                          controller.seekRelative(const Duration(seconds: 30)),
                      tooltip: '30 Sekunden vor',
                      icon: const Icon(Icons.forward_30),
                    ),
                    IconButton(
                      onPressed: controller.next,
                      icon: const Icon(Icons.skip_next),
                    ),
                    if (onExpand != null)
                      IconButton(
                        onPressed: onExpand,
                        tooltip: 'Player maximieren',
                        icon: const Icon(Icons.open_in_full),
                      ),
                  ],
                ),
                Row(
                  children: [
                    Text(_formatRemoteDuration(controller.position)),
                    Expanded(
                      child: Slider(
                        value: position,
                        max: maximum > 0 ? maximum : 1,
                        onChanged: maximum > 0
                            ? (value) => controller.seek(
                                Duration(milliseconds: value.round()),
                              )
                            : null,
                      ),
                    ),
                    Text(_formatRemoteDuration(controller.duration)),
                  ],
                ),
                Align(
                  alignment: Alignment.centerRight,
                  child: Wrap(
                    spacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      PlaybackSleepTimerButton(
                        timer: controller.sleepTimer,
                        supportsChapterEnd: controller.chapters.isNotEmpty,
                      ),
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
                    ],
                  ),
                ),
                if (controller.error case final error?)
                  Text(
                    error,
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

String _formatRemoteDuration(Duration value) {
  final hours = value.inHours;
  final minutes = (value.inMinutes % 60).toString().padLeft(2, '0');
  final seconds = (value.inSeconds % 60).toString().padLeft(2, '0');
  return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
}

String _remoteChapterSubtitle(FundusRemoteChapter chapter, int trackCount) {
  final parts = <String>[];
  if (trackCount > 1) parts.add('Datei ${chapter.trackIndex + 1}');
  parts.add('ab ${_formatRemoteDuration(chapter.position)}');
  if (chapter.duration case final duration?) {
    parts.add('Dauer ${_formatRemoteDuration(duration)}');
  }
  return parts.join(' · ');
}

Widget? _remoteTechnicalSubtitle(FundusRemoteTrack track) {
  final metadata = track.audioMetadata;
  if (metadata == null && track.size == null && track.duration == null) {
    return null;
  }
  final target = Platform.isAndroid
      ? AudioPlaybackTarget.android
      : AudioPlaybackTarget.desktop;
  final assessment = metadata?.assess(target);
  final parts = <String>[
    p.extension(track.title).replaceFirst('.', '').toUpperCase(),
  ];
  if (track.mimeType case final mime? when mime.trim().isNotEmpty) {
    parts.add(mime);
  }
  if (metadata != null) {
    parts
      ..add(metadata.container)
      ..add(metadata.codec)
      ..addAll([
        if (metadata.profile case final value?) value,
        if (metadata.channels case final value?)
          value == 1 ? 'Mono' : '$value Kanäle',
        if (metadata.sampleRateHz case final value?)
          '${(value / 1000).toStringAsFixed(value % 1000 == 0 ? 0 : 1)} kHz',
      ]);
  }
  if (track.duration case final duration?) {
    parts.add('Dauer ${_formatRemoteDuration(duration)}');
  }
  if (track.size case final bytes?) parts.add(_formatRemoteBytes(bytes));
  final label = switch (assessment?.status) {
    AudioCompatibilityStatus.compatible => 'geeignet',
    AudioCompatibilityStatus.warning => 'prüfen',
    AudioCompatibilityStatus.unsupported => 'nicht geeignet',
    AudioCompatibilityStatus.unknown => 'unbekannt',
    null => null,
  };
  final compatibility = label == null
      ? null
      : '${Platform.isAndroid ? 'Android' : 'Desktop'}: $label';
  return Text(
    [parts.join(' · '), if (compatibility != null) compatibility].join('\n'),
  );
}

String _formatRemoteBytes(int bytes) {
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}

String _remoteTrackLabel(FundusRemoteTrack track) {
  final episode = track.episode ?? parseVideoEpisode(track.title);
  if (episode == null || episode.title.isEmpty) return track.title;
  return '${episode.label} · ${episode.title}';
}

class _PairingScanner extends StatefulWidget {
  const _PairingScanner();

  @override
  State<_PairingScanner> createState() => _PairingScannerState();
}

class _PairingScannerState extends State<_PairingScanner> {
  bool _handled = false;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Fundus-QR-Code scannen')),
    body: MobileScanner(
      onDetect: (capture) {
        if (_handled) return;
        final value = capture.barcodes.firstOrNull?.rawValue;
        if (value == null) return;
        _handled = true;
        Navigator.pop(context, value);
      },
    ),
  );
}
