import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../diagnostics/fundus_diagnostics.dart';
import '../playback/playback_sleep_timer.dart';
import 'fundus_remote_client.dart';
import 'fundus_peer_server_controller.dart';
import 'fundus_remote_player_controller.dart';
import 'fundus_offline_store.dart';
import 'fundus_peer_discovery.dart';
import 'peer_server_identity_store.dart';

Future<void> showFundusRemoteServers(
  BuildContext context, {
  String? initialServerId,
  String? initialLibraryId,
  FundusPeerServerController? peerServer,
}) => Navigator.of(context).push(
  MaterialPageRoute<void>(
    builder: (_) => FundusRemoteServersView(
      initialServerId: initialServerId,
      initialLibraryId: initialLibraryId,
      peerServer: peerServer,
    ),
  ),
);

class FundusRemoteServersView extends StatefulWidget {
  const FundusRemoteServersView({
    super.key,
    this.initialServerId,
    this.initialLibraryId,
    this.peerServer,
  });

  final String? initialServerId;
  final String? initialLibraryId;
  final FundusPeerServerController? peerServer;

  @override
  State<FundusRemoteServersView> createState() =>
      _FundusRemoteServersViewState();
}

class _FundusRemoteServersViewState extends State<FundusRemoteServersView> {
  final _store = FundusRemoteServerStore();
  final _client = const FundusRemoteClient();
  final _offlineStore = FundusOfflineStore();
  final _peerDiscovery = FundusPeerDiscovery();
  List<FundusRemoteServer> _servers = const [];
  FundusRemoteServer? _selectedServer;
  List<FundusRemoteLibrary> _libraries = const [];
  FundusRemoteLibrary? _selectedLibrary;
  String? _offlineLibraryFilter;
  List<FundusRemoteWork> _works = const [];
  String? _selectedKind;
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
      _selectedKind = null;
    });
    try {
      final result = await _runWithReconnect(
        server,
        (active) => _client.works(active, library.id),
      );
      final activeServer = result.server;
      final works = result.value;
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
        : _RemotePlayerBar(controller: _remotePlayer!),
  );

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
    final server = _selectedServer!;
    final kinds = _works.map((work) => work.kind).toSet().toList()..sort();
    final works = _selectedKind == null
        ? _works
        : _works.where((work) => work.kind == _selectedKind).toList();
    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: ListTile(
            leading: BackButton(
              onPressed: () => setState(() => _selectedLibrary = null),
            ),
            title: Text(library.name),
            subtitle: Text('${works.length} Medien'),
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
                    selected: _selectedKind == null,
                    onSelected: (_) => setState(() => _selectedKind = null),
                  ),
                  const SizedBox(width: 8),
                  for (final kind in kinds) ...[
                    ChoiceChip(
                      label: Text(_kindLabel(kind)),
                      selected: _selectedKind == kind,
                      onSelected: (_) => setState(() => _selectedKind = kind),
                    ),
                    const SizedBox(width: 8),
                  ],
                ],
              ),
            ),
          ),
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
        ),
      ],
    );
  }

  Future<void> _showWork(
    FundusRemoteServer server,
    FundusRemoteLibrary library,
    FundusRemoteWork work,
  ) async {
    final key = _offlineKey(server, library, work);
    final isOffline = _offlineKeys.contains(key);
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
          offlineStore: _offlineStore,
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
            ],
          ),
        ),
      ),
    );
    if (action == 'play') await _playOffline(offline);
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
          offlineStore: _offlineStore,
        );
    if (_remotePlayer == null && mounted) {
      setState(() => _remotePlayer = player);
    }
    await player.open(server, library, work, offlineWork: offline);
  }
}

class _RemotePlayerBar extends StatelessWidget {
  const _RemotePlayerBar({required this.controller});

  final FundusRemotePlayerController controller;

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
                      _RemoteSleepTimerButton(controller: controller),
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

enum _RemoteSleepTimerChoice {
  off,
  minutes15,
  minutes30,
  minutes45,
  minutes60,
  trackEnd,
}

class _RemoteSleepTimerButton extends StatelessWidget {
  const _RemoteSleepTimerButton({required this.controller});

  final FundusRemotePlayerController controller;

  @override
  Widget build(BuildContext context) {
    final timer = controller.sleepTimer;
    final label = switch (timer.mode) {
      PlaybackSleepTimerMode.off => 'Sleep-Timer',
      PlaybackSleepTimerMode.endOfTrack => 'Am Trackende',
      PlaybackSleepTimerMode.duration => _remaining(timer.remaining),
    };
    return PopupMenuButton<_RemoteSleepTimerChoice>(
      tooltip: label,
      onSelected: (choice) => _select(timer, choice),
      itemBuilder: (context) => [
        CheckedPopupMenuItem(
          value: _RemoteSleepTimerChoice.off,
          checked: timer.mode == PlaybackSleepTimerMode.off,
          child: const Text('Aus'),
        ),
        for (final option in const [
          (_RemoteSleepTimerChoice.minutes15, 15),
          (_RemoteSleepTimerChoice.minutes30, 30),
          (_RemoteSleepTimerChoice.minutes45, 45),
          (_RemoteSleepTimerChoice.minutes60, 60),
        ])
          CheckedPopupMenuItem(
            value: option.$1,
            checked:
                timer.mode == PlaybackSleepTimerMode.duration &&
                timer.configuredDuration == Duration(minutes: option.$2),
            child: Text('${option.$2} Minuten'),
          ),
        CheckedPopupMenuItem(
          value: _RemoteSleepTimerChoice.trackEnd,
          checked: timer.mode == PlaybackSleepTimerMode.endOfTrack,
          child: const Text('Am Trackende'),
        ),
      ],
      child: Chip(
        avatar: Icon(
          timer.active ? Icons.bedtime : Icons.bedtime_outlined,
          size: 18,
        ),
        label: Text(label),
      ),
    );
  }

  static void _select(
    PlaybackSleepTimer timer,
    _RemoteSleepTimerChoice choice,
  ) {
    switch (choice) {
      case _RemoteSleepTimerChoice.off:
        timer.cancel();
      case _RemoteSleepTimerChoice.minutes15:
        timer.schedule(const Duration(minutes: 15));
      case _RemoteSleepTimerChoice.minutes30:
        timer.schedule(const Duration(minutes: 30));
      case _RemoteSleepTimerChoice.minutes45:
        timer.schedule(const Duration(minutes: 45));
      case _RemoteSleepTimerChoice.minutes60:
        timer.schedule(const Duration(minutes: 60));
      case _RemoteSleepTimerChoice.trackEnd:
        timer.scheduleEndOfTrack();
    }
  }

  static String _remaining(Duration? value) {
    if (value == null) return 'Sleep-Timer';
    final totalMinutes = value.inMinutes;
    final seconds = (value.inSeconds % 60).toString().padLeft(2, '0');
    if (totalMinutes < 60) return '$totalMinutes:$seconds';
    final hours = value.inHours;
    final minutes = (value.inMinutes % 60).toString().padLeft(2, '0');
    return '$hours:$minutes:$seconds';
  }
}

String _formatRemoteDuration(Duration value) {
  final hours = value.inHours;
  final minutes = (value.inMinutes % 60).toString().padLeft(2, '0');
  final seconds = (value.inSeconds % 60).toString().padLeft(2, '0');
  return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
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
