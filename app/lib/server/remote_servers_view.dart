import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:fundus_core/fundus_core.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../diagnostics/fundus_diagnostics.dart';
import '../playback/playback_sleep_timer_button.dart';
import '../playback/playback_conflict_settings.dart';
import 'fundus_remote_client.dart';
import 'fundus_peer_server_controller.dart';
import 'fundus_remote_player_controller.dart';
import 'fundus_offline_store.dart';
import 'fundus_peer_discovery.dart';
import 'peer_server_identity_store.dart';
import 'remote_saved_view_store.dart';

enum _RemoteLayout { grid, list }

enum _RemoteGrouping { books, authors, series, narrators }

enum _RemoteLibrarySection { media, playlists }

Future<void> showFundusRemoteServers(
  BuildContext context, {
  String? initialServerId,
  String? initialLibraryId,
  FundusPeerServerController? peerServer,
  FundusOfflineStore? offlineStore,
}) => Navigator.of(context).push(
  MaterialPageRoute<void>(
    builder: (_) => FundusRemoteServersView(
      initialServerId: initialServerId,
      initialLibraryId: initialLibraryId,
      peerServer: peerServer,
      offlineStore: offlineStore,
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
  });

  final String? initialServerId;
  final String? initialLibraryId;
  final FundusPeerServerController? peerServer;
  final FundusOfflineStore? offlineStore;

  @override
  State<FundusRemoteServersView> createState() =>
      _FundusRemoteServersViewState();
}

class _FundusRemoteServersViewState extends State<FundusRemoteServersView> {
  final _store = FundusRemoteServerStore();
  final _client = const FundusRemoteClient();
  final _savedViewStore = const RemoteSavedViewStore();
  final _searchController = SearchController();
  late final FundusOfflineStore _offlineStore;
  final _peerDiscovery = FundusPeerDiscovery();
  List<FundusRemoteServer> _servers = const [];
  FundusRemoteServer? _selectedServer;
  List<FundusRemoteLibrary> _libraries = const [];
  FundusRemoteLibrary? _selectedLibrary;
  String? _offlineLibraryFilter;
  List<FundusRemoteWork> _works = const [];
  List<FundusRemotePlaylist> _playlists = const [];
  _RemoteLibrarySection _librarySection = _RemoteLibrarySection.media;
  LibraryWorkQuery _query = const LibraryWorkQuery(sort: LibraryWorkSort.title);
  List<LibrarySavedView> _savedViews = const [];
  _RemoteLayout _layout = _RemoteLayout.grid;
  _RemoteGrouping _grouping = _RemoteGrouping.books;
  String? _selectedGroup;
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
  late final AppLifecycleListener _lifecycleListener;

  @override
  void initState() {
    super.initState();
    _offlineStore = widget.offlineStore ?? FundusOfflineStore();
    _lifecycleListener = AppLifecycleListener(
      onInactive: () => unawaited(_remotePlayer?.persist()),
      onHide: () => unawaited(_remotePlayer?.persist()),
      onPause: () => unawaited(_remotePlayer?.persist()),
    );
    _load();
  }

  @override
  void dispose() {
    _lifecycleListener.dispose();
    _searchController.dispose();
    _remotePlayer?.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      var servers = await _store.load();
      final offlineWorks = await _offlineStore.listAll();
      if (!mounted) return;
      setState(() {
        _servers = servers;
        _offlineWorks = offlineWorks;
        _offlineKeys.addAll(
          offlineWorks.map(
            (work) => '${work.serverId}/${work.libraryId}/${work.workId}',
          ),
        );
        _busy = false;
      });
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
      _offlineLibraryFilter = null;
      _works = const [];
      _playlists = const [];
    });
    try {
      final result = await _runWithReconnect(
        server,
        (active) => _client.libraries(active),
      );
      final libraries = result.value;
      await _store.rememberLibraries(result.server, libraries);
      if (!mounted) return;
      setState(() {
        _selectedServer = result.server;
        _libraries = libraries;
        _busy = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = 'Server nicht erreichbar oder Berechtigung widerrufen.';
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
    });
    try {
      final result = await _runWithReconnect(
        server,
        (active) async => (
          works: await _client.works(active, library.id),
          playlists: await _client.playlists(active, library.id),
          views: await _savedViewStore.load(active.id, library.id),
        ),
      );
      final activeServer = result.server;
      final works = result.value.works;
      final playlists = result.value.playlists;
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
    if (!mounted) return;
    setState(() {
      _servers = servers;
      if (_selectedServer?.id == server.id) {
        _selectedServer = null;
        _selectedLibrary = null;
        _libraries = const [];
        _works = const [];
        _playlists = const [];
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
    final works = _offlineWorks
        .where((work) => work.libraryId == _offlineLibraryFilter)
        .toList();
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        ListTile(
          leading: BackButton(
            onPressed: () => setState(() => _offlineLibraryFilter = null),
          ),
          title: const Text('Offline-Medien'),
          subtitle: Text('${works.length} Medium/Medien auf diesem Gerät'),
        ),
        for (final offline in works)
          Card(
            child: ListTile(
              leading: offline.coverPath == null
                  ? Icon(_kindIcon(offline.kind))
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
    );
  }

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
    final server = _selectedServer!;
    final kinds = _works.map((work) => work.kind).toSet().toList()..sort();
    final byId = {for (final work in _works) work.id: work};
    var works = LibraryWorkSearch.apply(
      _works.map(_remoteSummary),
      _query,
    ).map((work) => byId[work.id]!).toList();
    if (_selectedGroup case final group?) {
      works = works
          .where((work) => _remoteGroupValues(work).contains(group))
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
                              if (_offlineKeys.contains(
                                _offlineKey(server, library, work),
                              ))
                                const Row(
                                  children: [
                                    Icon(Icons.download_done, size: 15),
                                    SizedBox(width: 4),
                                    Text('Offline'),
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
                    trailing: const Icon(Icons.chevron_right),
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

  Widget _remotePlaylistsView(FundusRemoteLibrary library) {
    final server = _selectedServer!;
    return ListView(
      padding: const EdgeInsets.only(bottom: 16),
      children: [
        ListTile(
          leading: BackButton(
            onPressed: () => setState(() => _selectedLibrary = null),
          ),
          title: Text(library.name),
          subtitle: Text('${_playlists.length} Playlist(en)'),
        ),
        _librarySectionSelector(),
        if (_playlists.isEmpty)
          const Padding(
            padding: EdgeInsets.all(32),
            child: Center(
              child: Text(
                'Auf diesem Server wurden noch keine Playlists gespeichert.',
                textAlign: TextAlign.center,
              ),
            ),
          ),
        for (final playlist in _playlists)
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

  LibraryWorkSummary _remoteSummary(FundusRemoteWork work) {
    final server = _selectedServer;
    final library = _selectedLibrary;
    final offline =
        server != null &&
        library != null &&
        _offlineKeys.contains(_offlineKey(server, library, work));
    return LibraryWorkSummary(
      id: work.id,
      kind: work.kind,
      title: work.title,
      author: work.authors.firstOrNull ?? 'Unbekannt',
      authors: work.authors,
      fileCount: work.fileCount,
      addedAt: work.addedAt ?? DateTime.fromMillisecondsSinceEpoch(0),
      series: work.series,
      seriesSequence: work.seriesSequence?.toDouble(),
      language: work.language,
      subtitle: work.subtitle,
      description: work.description,
      narrators: work.narrators,
      publisher: work.publisher,
      publishedYear: work.publishedYear,
      progressPosition: work.progressPosition,
      progressDuration: work.progressDuration,
      progressTrackIndex: work.progressTrackIndex,
      progressFinished: work.progressFinished,
      tags: work.tags,
      lastListenedAt: work.lastListenedAt,
      offline: offline,
    );
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

  Future<void> _showWork(
    FundusRemoteServer server,
    FundusRemoteLibrary library,
    FundusRemoteWork work,
  ) async {
    final key = _offlineKey(server, library, work);
    final isOffline = _offlineKeys.contains(key);
    var detailTracks = <FundusRemoteTrack>[];
    if (isOffline) {
      final offline = await _offlineStore.lookup(
        serverId: server.id,
        libraryId: library.id,
        workId: work.id,
      );
      detailTracks = [
        for (final track in offline?.tracks ?? const <FundusOfflineTrack>[])
          FundusRemoteTrack(
            id: track.id,
            title: track.title,
            position: track.position,
            duration: track.duration,
            audioMetadata: track.audioMetadata,
          ),
      ];
    } else {
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
                    child: work.hasCover
                        ? _remoteCover(
                            server,
                            library,
                            work,
                            borderRadius: BorderRadius.circular(10),
                          )
                        : const Icon(Icons.audiotrack, size: 72),
                  ),
                  const SizedBox(width: 18),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          work.title,
                          style: Theme.of(context).textTheme.headlineSmall,
                        ),
                        const SizedBox(height: 6),
                        Text(work.authors.join(', ')),
                        if (work.subtitle case final subtitle?) ...[
                          const SizedBox(height: 4),
                          Text(subtitle),
                        ],
                        if (work.series case final series?) ...[
                          const SizedBox(height: 6),
                          Text(
                            work.seriesSequence == null
                                ? series
                                : '$series · Band '
                                      '${_formatRemoteSequence(work.seriesSequence!)}',
                          ),
                        ],
                        const SizedBox(height: 10),
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: [
                            for (final narrator in work.narrators)
                              Chip(
                                avatar: const Icon(Icons.mic_none, size: 16),
                                label: Text(narrator),
                              ),
                            if (work.language case final language?)
                              Chip(label: Text(_remoteLanguage(language))),
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
                            Chip(label: Text('${work.fileCount} Datei(en)')),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
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
              if (work.description case final description?) ...[
                const SizedBox(height: 20),
                Text(description),
              ],
              if (detailTracks.isNotEmpty) ...[
                const SizedBox(height: 20),
                Text('Dateien', style: Theme.of(context).textTheme.titleMedium),
                for (var index = 0; index < detailTracks.length; index++)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Text('${index + 1}'),
                    title: Text(detailTracks[index].title),
                    subtitle: _remoteTechnicalSubtitle(detailTracks[index]),
                    trailing: detailTracks[index].duration == null
                        ? null
                        : Text(
                            _formatRemoteDuration(
                              detailTracks[index].duration!,
                            ),
                          ),
                  ),
              ],
              const SizedBox(height: 24),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: () => Navigator.pop(context, 'play'),
                      icon: const Icon(Icons.play_arrow),
                      label: const Text('Abspielen / fortsetzen'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  IconButton.filledTonal(
                    onPressed: () => Navigator.pop(
                      context,
                      isOffline ? 'remove_download' : 'download',
                    ),
                    tooltip: isOffline
                        ? 'Offline-Kopie löschen'
                        : 'Offline speichern',
                    icon: Icon(
                      isOffline ? Icons.download_done : Icons.download_outlined,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    if (action == 'download') {
      await _downloadWork(server, library, work);
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
    if (action != 'play' || !mounted) return;
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
    final offlineWork = isOffline
        ? await _offlineStore.lookup(
            serverId: server.id,
            libraryId: library.id,
            workId: work.id,
          )
        : null;
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
    FundusRemoteWork work,
  ) async {
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
      () => _runWithReconnect(
        server,
        (active) => _client.cover(active, library.id, work.id),
      ).then((result) => result.value),
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

  Future<({FundusRemoteServer server, T value})> _runWithReconnect<T>(
    FundusRemoteServer server,
    Future<T> Function(FundusRemoteServer server) operation,
  ) async {
    try {
      return (server: server, value: await operation(server));
    } catch (firstError) {
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
        unawaited(
          FundusDiagnostics.instance.record('remote.reconnect_completed', {
            'server_id': server.id,
            'endpoint_changed': relocated.baseUri != server.baseUri,
          }),
        );
        return (server: relocated, value: value);
      } catch (retryError) {
        unawaited(
          FundusDiagnostics.instance.record('remote.reconnect_failed', {
            'server_id': server.id,
            'reason': _safeNetworkError(retryError),
          }),
        );
        rethrow;
      }
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
    'image' => 'Bild',
    'document' || 'archive' => 'Dokument',
    _ => kind,
  };

  static IconData _kindIcon(String kind) => switch (kind) {
    'movie' || 'video' || 'series' || 'tv' => Icons.movie_outlined,
    'podcast' => Icons.podcasts_outlined,
    'music' => Icons.music_note_outlined,
    'ebook' || 'book' => Icons.menu_book_outlined,
    'image' => Icons.image_outlined,
    'document' || 'archive' => Icons.description_outlined,
    _ => Icons.audiotrack,
  };

  static String _offlineSubtitle(FundusOfflineWork work) {
    final values = <String>[
      if (work.authors.isNotEmpty) work.authors.join(', '),
      if (work.series != null) work.series!,
      'Offline',
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

  Future<void> _showOfflineWork(FundusOfflineWork offline) async {
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
                ],
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
              const SizedBox(height: 24),
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
    if (action == 'play') {
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
                  onTap: () => controller.jumpToTrack(index),
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
  if (metadata == null) return null;
  final target = Platform.isAndroid
      ? AudioPlaybackTarget.android
      : AudioPlaybackTarget.desktop;
  final assessment = metadata.assess(target);
  final parts = <String>[
    metadata.container,
    metadata.codec,
    ?metadata.profile,
    if (metadata.channels case final value?)
      value == 1 ? 'Mono' : '$value Kanäle',
    if (metadata.sampleRateHz case final value?)
      '${(value / 1000).toStringAsFixed(value % 1000 == 0 ? 0 : 1)} kHz',
  ];
  final label = switch (assessment.status) {
    AudioCompatibilityStatus.compatible => 'geeignet',
    AudioCompatibilityStatus.warning => 'prüfen',
    AudioCompatibilityStatus.unsupported => 'nicht geeignet',
    AudioCompatibilityStatus.unknown => 'unbekannt',
  };
  return Text(
    '${parts.join(' · ')}\n${Platform.isAndroid ? 'Android' : 'Desktop'}: $label',
  );
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
