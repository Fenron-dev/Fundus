import 'dart:async';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:fundus_core/fundus_core.dart';
import 'package:media_kit/media_kit.dart';

import 'playback/fundus_player_controller.dart';
import 'playback/playback_sleep_timer.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
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
  ThemeMode _themeMode = ThemeMode.dark;
  FundusLibrary? _library;
  List<LibraryWorkSummary>? _works;
  LibraryIndexEvent? _indexEvent;
  FundusPlayerController? _player;
  String? _error;
  bool _busy = false;
  late final AppLifecycleListener _lifecycleListener;

  @override
  void initState() {
    super.initState();
    _works = widget.initialWorks;
    _lifecycleListener = AppLifecycleListener(
      onInactive: () => unawaited(_player?.persist()),
      onHide: () => unawaited(_player?.persist()),
      onPause: () => unawaited(_player?.persist()),
      onExitRequested: () async {
        await _player?.persist();
        return AppExitResponse.exit;
      },
    );
  }

  @override
  void dispose() {
    _lifecycleListener.dispose();
    _player?.dispose();
    _library?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
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
              onToggleTheme: _toggleTheme,
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
              onToggleTheme: _toggleTheme,
            ),
    );
  }

  void _toggleTheme() => setState(() {
    _themeMode = _themeMode == ThemeMode.dark
        ? ThemeMode.light
        : ThemeMode.dark;
  });

  Future<void> _chooseLibrary({required bool create}) async {
    final path = await FilePicker.getDirectoryPath(
      dialogTitle: create
          ? 'Ordner für die Fundus-Bibliothek wählen'
          : 'Fundus-Bibliothek öffnen',
    );
    if (path == null || !mounted) return;
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
      _works = library.listWorks();
      if (mounted) setState(() {});
      await _scan();
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _scan() async {
    final library = _library;
    if (library == null || library.isReadOnly) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await for (final event in library.index()) {
        if (!mounted) return;
        setState(() => _indexEvent = event);
      }
      if (mounted) setState(() => _works = library.listWorks());
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _startPlayback(LibraryWorkSummary work) async {
    final library = _library;
    if (library == null) return;
    final player = _player ?? FundusPlayerController();
    if (_player == null) setState(() => _player = player);
    await player.open(library, work);
  }

  Future<void> _stopPlayer() async {
    final player = _player;
    if (player == null) return;
    await player.close();
    player.dispose();
    _player = null;
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
    required this.onToggleTheme,
  });

  final bool busy;
  final String? error;
  final VoidCallback onCreate;
  final VoidCallback onOpen;
  final VoidCallback onToggleTheme;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Fundus'),
        actions: [
          IconButton(
            onPressed: onToggleTheme,
            tooltip: 'Theme wechseln',
            icon: const Icon(Icons.contrast),
          ),
        ],
      ),
      body: Center(
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
    );
  }
}

class LibraryShell extends StatefulWidget {
  const LibraryShell({
    super.key,
    required this.works,
    required this.onToggleTheme,
    this.library,
    this.libraryName,
    this.indexEvent,
    this.onRescan,
    this.onClose,
    this.player,
    this.onPlay,
  });

  final List<LibraryWorkSummary> works;
  final FundusLibrary? library;
  final VoidCallback onToggleTheme;
  final String? libraryName;
  final LibraryIndexEvent? indexEvent;
  final VoidCallback? onRescan;
  final VoidCallback? onClose;
  final FundusPlayerController? player;
  final ValueChanged<LibraryWorkSummary>? onPlay;

  @override
  State<LibraryShell> createState() => _LibraryShellState();
}

class _LibraryShellState extends State<LibraryShell> {
  int _selectedIndex = 0;
  int _mobileDestination = 0;
  LibraryWorkQuery _query = const LibraryWorkQuery();

  List<LibraryWorkSummary> get _visibleWorks =>
      LibraryWorkSearch.apply(widget.works, _query);

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
    final works = _visibleWorks;
    final selected = works.isEmpty
        ? null
        : works[_selectedIndex.clamp(0, works.length - 1)];
    return Scaffold(
      bottomNavigationBar: widget.player == null
          ? null
          : _PlayerBar(controller: widget.player!),
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
            ),
            Expanded(
              child: Row(
                children: [
                  const SizedBox(width: 236, child: _Sidebar()),
                  const VerticalDivider(width: 1),
                  Expanded(child: _library(context)),
                  const VerticalDivider(width: 1),
                  SizedBox(
                    width: 368,
                    child: _DetailPanel(
                      work: selected,
                      library: widget.library,
                      player: widget.player,
                      onPlay: widget.onPlay,
                    ),
                  ),
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
      bottomNavigationBar: widget.player == null
          ? null
          : _PlayerBar(controller: widget.player!),
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
            ),
            Expanded(
              child: Row(
                children: [
                  NavigationRail(
                    selectedIndex: 0,
                    labelType: NavigationRailLabelType.all,
                    destinations: const [
                      NavigationRailDestination(
                        icon: Icon(Icons.headphones_outlined),
                        selectedIcon: Icon(Icons.headphones),
                        label: Text('Hörbücher'),
                      ),
                      NavigationRailDestination(
                        icon: Icon(Icons.explore_outlined),
                        label: Text('Entdecken'),
                      ),
                    ],
                  ),
                  const VerticalDivider(width: 1),
                  Expanded(child: _library(context, detailAsDialog: true)),
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
      const Center(child: Text('Downloads')),
      const Center(child: Text('Einstellungen')),
    ];
    return Scaffold(
      appBar: AppBar(
        title: const Text('Hörbücher & Hörspiele'),
        actions: [
          IconButton(
            onPressed: widget.onToggleTheme,
            tooltip: 'Theme wechseln',
            icon: const Icon(Icons.contrast),
          ),
        ],
      ),
      body: pages[_mobileDestination],
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.player != null)
            _PlayerBar(controller: widget.player!, compact: true),
          NavigationBar(
            selectedIndex: _mobileDestination,
            onDestinationSelected: (value) =>
                setState(() => _mobileDestination = value),
            destinations: const [
              NavigationDestination(
                icon: Icon(Icons.library_books_outlined),
                label: 'Bibliothek',
              ),
              NavigationDestination(icon: Icon(Icons.search), label: 'Suche'),
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

  Widget _library(
    BuildContext context, {
    bool detailAsDialog = false,
    bool showSearch = false,
  }) {
    final works = _visibleWorks;
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
          child: Row(
            children: [
              Text(
                'Hörbücher & Hörspiele',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const Spacer(),
              _MediaFilterButton(
                selectedKinds: _query.kinds,
                onChanged: _setKinds,
              ),
              const SizedBox(width: 8),
              MenuAnchor(
                builder: (context, controller, child) => OutlinedButton.icon(
                  onPressed: controller.isOpen
                      ? controller.close
                      : controller.open,
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
          ),
        ),
        Expanded(
          child: works.isEmpty
              ? _EmptyLibrary(
                  searchActive:
                      _query.text.isNotEmpty || _query.kinds.isNotEmpty,
                )
              : GridView.builder(
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
                      selected: !detailAsDialog && index == _selectedIndex,
                      onTap: () {
                        setState(() => _selectedIndex = index);
                        if (detailAsDialog) {
                          showModalBottomSheet<void>(
                            context: context,
                            isScrollControlled: true,
                            showDragHandle: true,
                            builder: (context) => FractionallySizedBox(
                              heightFactor: .82,
                              child: _DetailPanel(
                                work: work,
                                library: widget.library,
                                player: widget.player,
                                onPlay: widget.onPlay,
                              ),
                            ),
                          );
                        }
                      },
                    );
                  },
                ),
        ),
      ],
    );
  }

  void _setSearch(String value) => setState(() {
    _selectedIndex = 0;
    _query = _query.copyWith(text: value);
  });

  void _setKinds(Set<String> value) => setState(() {
    _selectedIndex = 0;
    _query = _query.copyWith(kinds: value);
  });

  void _setSort(LibraryWorkSort value) => setState(() {
    _selectedIndex = 0;
    _query = _query.copyWith(sort: value);
  });

  static String _sortLabel(LibraryWorkSort sort) => switch (sort) {
    LibraryWorkSort.relevance => 'Relevanz',
    LibraryWorkSort.recentlyAdded => 'Zuletzt hinzugefügt',
    LibraryWorkSort.title => 'Titel A–Z',
    LibraryWorkSort.author => 'Autor A–Z',
    LibraryWorkSort.series => 'Serie & Reihenfolge',
  };
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.onToggleTheme,
    this.libraryName,
    this.indexEvent,
    this.onRescan,
    this.onClose,
    required this.onSearch,
  });

  final VoidCallback onToggleTheme;
  final String? libraryName;
  final LibraryIndexEvent? indexEvent;
  final VoidCallback? onRescan;
  final VoidCallback? onClose;
  final ValueChanged<String> onSearch;

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
  const _Sidebar();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(10),
      children: const [
        _SectionLabel('Bibliothek'),
        ListTile(
          leading: Icon(Icons.headphones),
          title: Text('Hörbücher'),
          selected: true,
        ),
        ListTile(
          leading: Icon(Icons.movie_outlined),
          title: Text('Filme & Serien'),
        ),
        ListTile(
          leading: Icon(Icons.menu_book_outlined),
          title: Text('E-Books & PDFs'),
        ),
        SizedBox(height: 12),
        _SectionLabel('Entdecken'),
        ListTile(
          leading: Icon(Icons.account_tree_outlined),
          title: Text('Serien'),
        ),
        ListTile(leading: Icon(Icons.people_outline), title: Text('Personen')),
        ListTile(leading: Icon(Icons.tag), title: Text('Tags')),
        ListTile(leading: Icon(Icons.star_outline), title: Text('Sammlungen')),
        ListTile(leading: Icon(Icons.folder_outlined), title: Text('Ordner')),
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

class _WorkCard extends StatelessWidget {
  const _WorkCard({
    required this.work,
    required this.selected,
    required this.onTap,
  });

  final LibraryWorkSummary work;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      selected: selected,
      label: '${work.title}, ${work.author}',
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
                      children: [_WorkCover(work: work, iconSize: 42)],
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Text(work.title, maxLines: 2, overflow: TextOverflow.ellipsis),
                Text(
                  work.series == null
                      ? work.author
                      : '${work.author} · ${work.series}',
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

class _DetailPanel extends StatefulWidget {
  const _DetailPanel({
    required this.work,
    this.library,
    this.player,
    this.onPlay,
  });

  final LibraryWorkSummary? work;
  final FundusLibrary? library;
  final FundusPlayerController? player;
  final ValueChanged<LibraryWorkSummary>? onPlay;

  @override
  State<_DetailPanel> createState() => _DetailPanelState();
}

class _DetailPanelState extends State<_DetailPanel> {
  final _noteController = TextEditingController();
  WorkAnnotations _annotations = const WorkAnnotations();
  bool _saving = false;
  bool _bookmarkAvailable = false;

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
    _noteController.text = _annotations.note;
  }

  void _attachPlayer() {
    widget.player?.addListener(_syncPlayer);
    _syncPlayer(notify: false);
  }

  void _syncPlayer({bool notify = true}) {
    final next =
        widget.library != null &&
        widget.player?.work?.id == widget.work?.id &&
        widget.player?.track != null;
    if (next == _bookmarkAvailable) return;
    if (notify && mounted) {
      setState(() => _bookmarkAvailable = next);
    } else {
      _bookmarkAvailable = next;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.work == null) return const _EmptyLibrary();
    final selectedWork = widget.work!;
    final canBookmark = _bookmarkAvailable;
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const SizedBox(height: 8),
        Center(
          child: SizedBox.square(
            dimension: 180,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: _WorkCover(work: selectedWork, iconSize: 72),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Text(
          selectedWork.title,
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        Text(
          selectedWork.series == null
              ? selectedWork.author
              : '${selectedWork.author} · ${selectedWork.series}',
        ),
        const SizedBox(height: 14),
        Text('${selectedWork.fileCount} Mediendatei(en)'),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: widget.onPlay == null
              ? null
              : () => widget.onPlay!(selectedWork),
          icon: const Icon(Icons.play_arrow),
          label: const Text('Weiterhören'),
        ),
        const SizedBox(height: 20),
        Text('Erreichbar über', style: Theme.of(context).textTheme.labelMedium),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            Chip(label: Text('Autor: ${selectedWork.author}')),
            if (selectedWork.series case final series?)
              Chip(
                label: Text(
                  selectedWork.seriesSequence == null
                      ? 'Serie: $series'
                      : 'Serie: $series · Band ${_sequence(selectedWork.seriesSequence!)}',
                ),
              ),
          ],
        ),
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
        TextField(
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

  Future<void> _addTag() async {
    final controller = TextEditingController();
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Tag hinzufügen'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'z. B. Fantasy'),
          onSubmitted: (value) => Navigator.pop(context, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Hinzufügen'),
          ),
        ],
      ),
    );
    controller.dispose();
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
    await _runSave(
      () => library.saveWorkNote(work.id, _noteController.text),
      successMessage: 'Notiz gespeichert.',
    );
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

  Future<void> _runSave(
    Future<WorkAnnotations> Function() action, {
    String? successMessage,
  }) async {
    setState(() => _saving = true);
    try {
      final annotations = await action();
      if (!mounted) return;
      setState(() {
        _annotations = annotations;
        _noteController.text = annotations.note;
      });
      if (successMessage != null) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(successMessage)));
      }
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Speichern fehlgeschlagen: $error')),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  static String _sequence(double value) => value == value.roundToDouble()
      ? value.toInt().toString()
      : value.toString().replaceAll('.', ',');

  static String _time(Duration value) {
    final hours = value.inHours.toString().padLeft(2, '0');
    final minutes = (value.inMinutes % 60).toString().padLeft(2, '0');
    final seconds = (value.inSeconds % 60).toString().padLeft(2, '0');
    return '$hours:$minutes:$seconds';
  }
}

class _WorkCover extends StatelessWidget {
  const _WorkCover({required this.work, required this.iconSize});

  final LibraryWorkSummary work;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
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

class _PlayerBar extends StatelessWidget {
  const _PlayerBar({required this.controller, this.compact = false});

  final FundusPlayerController controller;
  final bool compact;

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
              height: 68,
              child: Row(
                children: [
                  IconButton(
                    onPressed: controller.loading
                        ? null
                        : controller.playOrPause,
                    icon: controller.loading
                        ? const SizedBox.square(
                            dimension: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Icon(
                            controller.playing ? Icons.pause : Icons.play_arrow,
                          ),
                  ),
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
                          '${track?.title ?? ''} · ${_time(controller.position)}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: controller.next,
                    tooltip: 'Nächster Track',
                    icon: const Icon(Icons.skip_next),
                  ),
                  _SleepTimerButton(controller: controller, compact: true),
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
                        _SleepTimerButton(controller: controller),
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

  static String _time(Duration duration) {
    final hours = duration.inHours;
    final minutes = (duration.inMinutes % 60).toString().padLeft(2, '0');
    final seconds = (duration.inSeconds % 60).toString().padLeft(2, '0');
    return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
  }
}

enum _SleepTimerChoice {
  off,
  minutes15,
  minutes30,
  minutes45,
  minutes60,
  trackEnd,
}

class _SleepTimerButton extends StatelessWidget {
  const _SleepTimerButton({required this.controller, this.compact = false});

  final FundusPlayerController controller;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final timer = controller.sleepTimer;
    final label = switch (timer.mode) {
      PlaybackSleepTimerMode.off => 'Sleep-Timer',
      PlaybackSleepTimerMode.endOfTrack => 'Am Trackende',
      PlaybackSleepTimerMode.duration => _remaining(timer.remaining),
    };
    return PopupMenuButton<_SleepTimerChoice>(
      tooltip: label,
      onSelected: (choice) => _select(timer, choice),
      itemBuilder: (context) => [
        CheckedPopupMenuItem(
          value: _SleepTimerChoice.off,
          checked: timer.mode == PlaybackSleepTimerMode.off,
          child: const Text('Aus'),
        ),
        for (final option in const [
          (_SleepTimerChoice.minutes15, 15),
          (_SleepTimerChoice.minutes30, 30),
          (_SleepTimerChoice.minutes45, 45),
          (_SleepTimerChoice.minutes60, 60),
        ])
          CheckedPopupMenuItem(
            value: option.$1,
            checked:
                timer.mode == PlaybackSleepTimerMode.duration &&
                timer.configuredDuration == Duration(minutes: option.$2),
            child: Text('${option.$2} Minuten'),
          ),
        CheckedPopupMenuItem(
          value: _SleepTimerChoice.trackEnd,
          checked: timer.mode == PlaybackSleepTimerMode.endOfTrack,
          child: const Text('Am Trackende'),
        ),
      ],
      child: compact
          ? Padding(
              padding: const EdgeInsets.all(8),
              child: Badge(
                isLabelVisible: timer.active,
                child: Icon(
                  timer.active ? Icons.bedtime : Icons.bedtime_outlined,
                ),
              ),
            )
          : Chip(
              avatar: Icon(
                timer.active ? Icons.bedtime : Icons.bedtime_outlined,
                size: 18,
              ),
              label: Text(label),
            ),
    );
  }

  static void _select(PlaybackSleepTimer timer, _SleepTimerChoice choice) {
    switch (choice) {
      case _SleepTimerChoice.off:
        timer.cancel();
      case _SleepTimerChoice.minutes15:
        timer.schedule(const Duration(minutes: 15));
      case _SleepTimerChoice.minutes30:
        timer.schedule(const Duration(minutes: 30));
      case _SleepTimerChoice.minutes45:
        timer.schedule(const Duration(minutes: 45));
      case _SleepTimerChoice.minutes60:
        timer.schedule(const Duration(minutes: 60));
      case _SleepTimerChoice.trackEnd:
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
