import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:fundus_core/fundus_core.dart';

void main() => runApp(const FundusApp());

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
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _works = widget.initialWorks;
  }

  @override
  void dispose() {
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
              libraryName: _library?.root.path
                  .split(Platform.pathSeparator)
                  .last,
              indexEvent: _indexEvent,
              onRescan: _library == null || _busy ? null : _scan,
              onClose: _library == null ? null : _closeLibrary,
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

  void _closeLibrary() {
    _library?.close();
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
    this.libraryName,
    this.indexEvent,
    this.onRescan,
    this.onClose,
  });

  final List<LibraryWorkSummary> works;
  final VoidCallback onToggleTheme;
  final String? libraryName;
  final LibraryIndexEvent? indexEvent;
  final VoidCallback? onRescan;
  final VoidCallback? onClose;

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
                  SizedBox(width: 368, child: _DetailPanel(work: selected)),
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
      bottomNavigationBar: NavigationBar(
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
          NavigationDestination(icon: Icon(Icons.more_horiz), label: 'Mehr'),
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
                              child: _DetailPanel(work: work),
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
                      children: [
                        const Center(child: Icon(Icons.music_note, size: 42)),
                      ],
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

class _DetailPanel extends StatelessWidget {
  const _DetailPanel({required this.work});

  final LibraryWorkSummary? work;

  @override
  Widget build(BuildContext context) {
    if (work == null) return const _EmptyLibrary();
    final selectedWork = work!;
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const SizedBox(height: 8),
        const Icon(Icons.music_note, size: 72),
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
          onPressed: () {},
          icon: const Icon(Icons.play_arrow),
          label: const Text('Weiterhören'),
        ),
        const SizedBox(height: 20),
        Text('Erreichbar über', style: Theme.of(context).textTheme.labelMedium),
        const SizedBox(height: 8),
        const Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            Chip(label: Text('Serie: Winnetou')),
            Chip(label: Text('Autor: Karl May')),
            Chip(label: Text('#Abenteuer')),
          ],
        ),
        const SizedBox(height: 20),
        Text('Lesezeichen', style: Theme.of(context).textTheme.titleSmall),
        const ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Text('42:08'),
          title: Text('Versammlung der Apachen'),
        ),
        const SizedBox(height: 12),
        Text('Notizen', style: Theme.of(context).textTheme.titleSmall),
        const TextField(
          minLines: 4,
          maxLines: 8,
          decoration: InputDecoration(hintText: 'Notiz schreiben …'),
        ),
      ],
    );
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
