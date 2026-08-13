import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../playback/playback_conflict_settings.dart';
import '../playback/playback_shake_restart.dart';
import '../settings/fundus_settings_snapshot.dart';
import 'fundus_peer_server_controller.dart';
import 'fundus_offline_store.dart';
import 'remote_servers_view.dart';

Future<void> showFundusServerSettings(
  BuildContext context,
  FundusPeerServerController controller, {
  FundusOfflineStore? offlineStore,
  ThemeMode themeMode = ThemeMode.dark,
  ValueChanged<ThemeMode>? onThemeModeChanged,
  VoidCallback? onExportDiagnostics,
}) => showDialog<void>(
  context: context,
  builder: (context) => Dialog(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 980, maxHeight: 820),
      child: _ServerSettings(
        controller: controller,
        offlineStore: offlineStore,
        themeMode: themeMode,
        onThemeModeChanged: onThemeModeChanged,
        onExportDiagnostics: onExportDiagnostics,
      ),
    ),
  ),
);

class _ServerSettings extends StatelessWidget {
  const _ServerSettings({
    required this.controller,
    required this.themeMode,
    this.offlineStore,
    this.onThemeModeChanged,
    this.onExportDiagnostics,
  });

  final FundusPeerServerController controller;
  final FundusOfflineStore? offlineStore;
  final ThemeMode themeMode;
  final ValueChanged<ThemeMode>? onThemeModeChanged;
  final VoidCallback? onExportDiagnostics;

  @override
  Widget build(BuildContext context) => DefaultTabController(
    length: 6,
    child: AnimatedBuilder(
      animation: controller,
      builder: (context, child) => Scaffold(
        appBar: AppBar(
          title: const Text('Einstellungen'),
          automaticallyImplyLeading: false,
          actions: [
            IconButton(
              onPressed: () => Navigator.pop(context),
              tooltip: 'Schließen',
              icon: const Icon(Icons.close),
            ),
          ],
          bottom: const TabBar(
            isScrollable: true,
            tabs: [
              Tab(icon: Icon(Icons.play_circle_outline), text: 'Wiedergabe'),
              Tab(icon: Icon(Icons.palette_outlined), text: 'Darstellung'),
              Tab(icon: Icon(Icons.video_library_outlined), text: 'Bibliothek'),
              Tab(icon: Icon(Icons.search), text: 'Suche'),
              Tab(icon: Icon(Icons.lan_outlined), text: 'Server'),
              Tab(icon: Icon(Icons.bug_report_outlined), text: 'Diagnose'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _settingsList([
              const _SettingsIntro(
                title: 'Wiedergabe',
                description: 'Fortsetzen, Konflikte und Sleep-Timer-Verhalten.',
                scope: FundusSettingScope.userProfile,
              ),
              const PlaybackConflictSettingTile(),
              const Divider(),
              const PlaybackShakeSettingTile(),
            ]),
            _settingsList([
              const _SettingsIntro(
                title: 'Darstellung',
                description: 'Erscheinungsbild auf diesem Gerät.',
                scope: FundusSettingScope.device,
              ),
              ListTile(
                leading: const Icon(Icons.contrast),
                title: const Text('Farbschema'),
                subtitle: const Text('Gilt nur für dieses Gerät.'),
                trailing: SegmentedButton<ThemeMode>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(
                      value: ThemeMode.system,
                      label: Text('System'),
                    ),
                    ButtonSegment(value: ThemeMode.light, label: Text('Hell')),
                    ButtonSegment(value: ThemeMode.dark, label: Text('Dunkel')),
                  ],
                  selected: {themeMode},
                  onSelectionChanged: onThemeModeChanged == null
                      ? null
                      : (value) => onThemeModeChanged!(value.single),
                ),
              ),
            ]),
            _librarySettings(context),
            _searchSettings(context),
            _serverSettings(context),
            _diagnosticSettings(context),
          ],
        ),
      ),
    ),
  );

  Widget _settingsList(List<Widget> children) => ListView(
    padding: const EdgeInsets.fromLTRB(24, 16, 24, 28),
    children: children,
  );

  Widget _librarySettings(BuildContext context) => _settingsList([
    const _SettingsIntro(
      title: 'Bibliothek',
      description: 'Portable Bibliotheksdaten und verfügbare Medienordner.',
      scope: FundusSettingScope.library,
    ),
    Card(
      child: Column(
        children: [
          for (var index = 0; index < controller.libraries.length; index++) ...[
            _libraryTile(context, controller.libraries[index]),
            if (index < controller.libraries.length - 1)
              const Divider(height: 1),
          ],
          if (controller.libraries.isEmpty)
            const Padding(
              padding: EdgeInsets.all(18),
              child: Text('Noch keine Bibliothek bekannt.'),
            ),
        ],
      ),
    ),
    const SizedBox(height: 12),
    const Card(
      child: ListTile(
        leading: Icon(Icons.save_outlined),
        title: Text('Portable Einstellungen'),
        subtitle: Text(
          'Tags, Metadaten, Ansichten und Nutzerdaten werden innerhalb der '
          'jeweiligen Bibliothek gespiegelt.',
        ),
        trailing: _ScopeChip(scope: FundusSettingScope.library),
      ),
    ),
  ]);

  Widget _searchSettings(BuildContext context) => _settingsList(const [
    _SettingsIntro(
      title: 'Suche',
      description: 'Fuzzy-Suche, kombinierbare Filter und Ansichten.',
      scope: FundusSettingScope.library,
    ),
    Card(
      child: ListTile(
        leading: Icon(Icons.manage_search),
        title: Text('Fuzzy-Suche aktiv'),
        subtitle: Text(
          'Kleine Tippfehler in Titeln, Personen, Serien und Tags werden '
          'automatisch toleriert.',
        ),
        trailing: _ScopeChip(scope: FundusSettingScope.userProfile),
      ),
    ),
    Card(
      child: ListTile(
        leading: Icon(Icons.bookmarks_outlined),
        title: Text('Gespeicherte Ansichten'),
        subtitle: Text(
          'Lokale Ansichten reisen mit der Bibliothek; Remote-Ansichten '
          'bleiben auf diesem Gerät nach Server und Bibliothek getrennt.',
        ),
        trailing: _ScopeChip(scope: FundusSettingScope.library),
      ),
    ),
  ]);

  Widget _serverSettings(BuildContext context) => _settingsList([
    const _SettingsIntro(
      title: 'Server und Geräte',
      description: 'Peer-Name, LAN-Freigabe, Pairing und Berechtigungen.',
      scope: FundusSettingScope.server,
    ),
    Card(
      child: ListTile(
        leading: const Icon(Icons.badge_outlined),
        title: const Text('Name dieses Geräts'),
        subtitle: Text(controller.deviceName),
        trailing: IconButton(
          onPressed: controller.isBusy ? null : () => _renameOwnDevice(context),
          tooltip: 'Gerätenamen ändern',
          icon: const Icon(Icons.edit_outlined),
        ),
      ),
    ),
    const SizedBox(height: 12),
    _statusCard(context),
    SwitchListTile.adaptive(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      secondary: const Icon(Icons.lan_outlined),
      title: const Text('Im lokalen Netzwerk freigeben'),
      subtitle: const Text(
        'TLS-verschlüsselt; neue Geräte benötigen QR-Code und PIN.',
      ),
      value: controller.lanEnabled,
      onChanged: controller.isBusy ? null : controller.setLanEnabled,
    ),
    Align(
      alignment: Alignment.centerLeft,
      child: OutlinedButton.icon(
        onPressed: () => showFundusRemoteServers(
          context,
          peerServer: controller,
          offlineStore: offlineStore,
        ),
        icon: const Icon(Icons.devices),
        label: const Text('Server und Downloads öffnen'),
      ),
    ),
    if (controller.lanEnabled && controller.isRunning) ...[
      const SizedBox(height: 12),
      _pairingCard(context),
    ],
    const SizedBox(height: 12),
    const Card(
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.shield_outlined),
            SizedBox(width: 12),
            Expanded(
              child: Text(
                'Ohne LAN-Freigabe ist der Server nur auf diesem Gerät '
                'erreichbar. Zertifikate, private Schlüssel und Pairing-Tokens '
                'werden niemals mit Einstellungen exportiert.',
              ),
            ),
          ],
        ),
      ),
    ),
  ]);

  Widget _diagnosticSettings(BuildContext context) => _settingsList([
    const _SettingsIntro(
      title: 'Diagnose und Übertragung',
      description: 'Protokolle sowie sicherer Export und Import.',
      scope: FundusSettingScope.device,
    ),
    if (onExportDiagnostics != null)
      Card(
        child: ListTile(
          leading: const Icon(Icons.description_outlined),
          title: const Text('Diagnoseprotokoll exportieren'),
          subtitle: const Text(
            'Enthält Ereignisse und technische IDs, aber keine Tokens oder '
            'absoluten Bibliothekspfade.',
          ),
          trailing: FilledButton.tonal(
            onPressed: onExportDiagnostics,
            child: const Text('Exportieren'),
          ),
        ),
      ),
    Card(
      child: Column(
        children: [
          ListTile(
            leading: const Icon(Icons.file_upload_outlined),
            title: const Text('Einstellungen exportieren'),
            subtitle: const Text(
              'Geräte-, Wiedergabe- und Serveroptionen ohne Geheimnisse.',
            ),
            trailing: FilledButton.tonal(
              onPressed: () => _exportSettings(context),
              child: const Text('Exportieren'),
            ),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.file_download_outlined),
            title: const Text('Einstellungen importieren'),
            subtitle: const Text(
              'Werte werden validiert und vor der Übernahme angezeigt.',
            ),
            trailing: FilledButton.tonal(
              onPressed: () => _importSettings(context),
              child: const Text('Importieren'),
            ),
          ),
        ],
      ),
    ),
    const Card(
      child: ListTile(
        leading: Icon(Icons.upgrade_outlined),
        title: Text('Bestehende Einstellungen übernommen'),
        subtitle: Text(
          'Die bisherigen Konflikt- und Schütteloptionen werden direkt aus '
          'ihrem bisherigen sicheren Speicher gelesen; kein Zurücksetzen nötig.',
        ),
        trailing: _ScopeChip(scope: FundusSettingScope.device),
      ),
    ),
  ]);

  Future<FundusSettingsSnapshot> _snapshot() => FundusSettingsSnapshot.capture(
    themeMode: themeMode,
    deviceName: controller.deviceName,
    lanEnabled: controller.lanEnabled,
  );

  Future<void> _exportSettings(BuildContext context) async {
    try {
      final snapshot = await _snapshot();
      final timestamp = DateTime.now().toUtc().toIso8601String().replaceAll(
        RegExp(r'[:.]'),
        '-',
      );
      final path = await FilePicker.saveFile(
        dialogTitle: 'Fundus-Einstellungen exportieren',
        fileName: 'fundus-settings-$timestamp.json',
        type: FileType.custom,
        allowedExtensions: const ['json'],
      );
      if (path == null) return;
      await File(path).writeAsString(snapshot.encode(), flush: true);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Einstellungen sicher exportiert.')),
      );
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Export fehlgeschlagen: $error')));
    }
  }

  Future<void> _importSettings(BuildContext context) async {
    try {
      final result = await FilePicker.pickFiles(
        dialogTitle: 'Fundus-Einstellungen importieren',
        type: FileType.custom,
        allowedExtensions: const ['json'],
        withData: true,
      );
      final selected = result?.files.single;
      if (selected == null) return;
      final bytes =
          selected.bytes ??
          (selected.path == null
              ? null
              : await File(selected.path!).readAsBytes());
      if (bytes == null ||
          bytes.length > FundusSettingsSnapshot.maximumImportBytes) {
        throw const FormatException(
          'Die Einstellungsdatei ist nicht lesbar oder zu groß.',
        );
      }
      final snapshot = FundusSettingsSnapshot.decode(
        String.fromCharCodes(bytes),
      );
      if (!context.mounted) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Importvorschau'),
          content: SizedBox(
            width: 560,
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final line in snapshot.preview())
                  ListTile(
                    dense: true,
                    leading: const Icon(Icons.check_circle_outline),
                    title: Text(line),
                  ),
                const Divider(),
                const Text(
                  'Bibliothekspfade, Zertifikate, Schlüssel und Pairing-Tokens '
                  'sind nicht Bestandteil des Imports.',
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
              child: const Text('Übernehmen'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
      await PlaybackConflictSettings.setAskBeforeJumping(
        snapshot.askOnProgressConflict,
      );
      await PlaybackShakeSettings.save(snapshot.shakeConfiguration);
      await controller.setDeviceName(snapshot.deviceName);
      await controller.setLanEnabled(snapshot.lanEnabled);
      onThemeModeChanged?.call(snapshot.themeMode);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Einstellungen wurden übernommen.')),
      );
    } on FormatException catch (error) {
      if (!context.mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Import nicht möglich'),
          content: Text(error.message),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Import fehlgeschlagen: $error')));
    }
  }

  Widget _statusCard(BuildContext context) {
    final running = controller.isRunning;
    final color = switch (controller.state) {
      PeerServerState.running => Colors.green,
      PeerServerState.failed => Theme.of(context).colorScheme.error,
      PeerServerState.starting || PeerServerState.stopping => Colors.orange,
      PeerServerState.stopped => Theme.of(context).colorScheme.outline,
    };
    final label = switch (controller.state) {
      PeerServerState.running => 'Server läuft',
      PeerServerState.failed => 'Serverfehler',
      PeerServerState.starting => 'Server startet …',
      PeerServerState.stopping => 'Server stoppt …',
      PeerServerState.stopped => 'Server ist aus',
    };
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.circle, size: 13, color: color),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(
                    label,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                FilledButton.icon(
                  onPressed:
                      controller.isBusy ||
                          (!running && !controller.hasSharedSources)
                      ? null
                      : running
                      ? controller.stop
                      : controller.start,
                  icon: Icon(running ? Icons.stop : Icons.play_arrow),
                  label: Text(running ? 'Stoppen' : 'Starten'),
                ),
              ],
            ),
            if (controller.localUri case final uri?) ...[
              const SizedBox(height: 10),
              SelectableText('${uri.host}:${uri.port}'),
            ],
            if (controller.error case final error?) ...[
              const SizedBox(height: 10),
              Text(
                error,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _pairingCard(BuildContext context) {
    final payload = controller.pairingPayload;
    final session = controller.pairingSession;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Gerät verbinden',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                if (session == null)
                  FilledButton.icon(
                    onPressed: controller.networkUris.isEmpty
                        ? null
                        : controller.beginPairing,
                    icon: const Icon(Icons.qr_code_2),
                    label: const Text('Pairing starten'),
                  )
                else
                  TextButton(
                    onPressed: controller.cancelPairing,
                    child: const Text('Abbrechen'),
                  ),
              ],
            ),
            if (controller.networkUris.isEmpty) ...[
              const SizedBox(height: 8),
              const Text('Keine verwendbare IPv4-Adresse im LAN gefunden.'),
            ] else ...[
              const SizedBox(height: 8),
              DropdownButtonFormField<Uri>(
                initialValue: controller.selectedPairingUri,
                decoration: const InputDecoration(
                  labelText: 'Adresse für den QR-Code',
                  border: OutlineInputBorder(),
                ),
                items: [
                  for (final uri in controller.networkUris)
                    DropdownMenuItem(value: uri, child: Text(uri.toString())),
                ],
                onChanged: session == null ? controller.setPairingUri : null,
              ),
            ],
            if (payload != null && session != null) ...[
              const SizedBox(height: 16),
              Center(
                child: DecoratedBox(
                  decoration: const BoxDecoration(color: Colors.white),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: QrImageView(
                      data: payload,
                      size: 220,
                      backgroundColor: Colors.white,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Center(
                child: Text(
                  session.pin,
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    letterSpacing: 8,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              Center(
                child: Text(
                  'Gültig bis ${TimeOfDay.fromDateTime(session.expiresAt).format(context)} Uhr',
                ),
              ),
            ],
            if (controller.pairedDevices.isNotEmpty) ...[
              const Divider(height: 32),
              Text(
                'Berechtigte Geräte',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              for (final device in controller.pairedDevices)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.devices_other),
                  title: Text(device.name),
                  subtitle: Text(
                    'Verbunden am ${MaterialLocalizations.of(context).formatShortDate(device.pairedAt.toLocal())}',
                  ),
                  trailing: Wrap(
                    children: [
                      IconButton(
                        onPressed: () => _renamePairedDevice(
                          context,
                          device.id,
                          device.name,
                        ),
                        tooltip: 'Gerät benennen',
                        icon: const Icon(Icons.edit_outlined),
                      ),
                      IconButton(
                        onPressed: () => controller.revokeDevice(device.id),
                        tooltip: 'Berechtigung widerrufen',
                        icon: const Icon(Icons.delete_outline),
                      ),
                    ],
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _libraryTile(BuildContext context, PeerSharedLibraryStatus library) =>
      ListTile(
        leading: Icon(
          Icons.circle,
          size: 12,
          color: library.available
              ? Colors.green
              : Theme.of(context).colorScheme.error,
        ),
        title: Text(library.name),
        subtitle: Text(
          library.error ??
              (library.workCount == null
                  ? library.path
                  : '${library.workCount} Werk(e) · gleichzeitig freigegeben'),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: Switch(
          value: library.shared,
          onChanged: controller.isBusy
              ? null
              : (value) => controller.setLibraryShared(library.path, value),
        ),
      );

  Future<String?> _askName(
    BuildContext context,
    String title,
    String current,
  ) async {
    final text = TextEditingController(text: current);
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: text,
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
            onPressed: () => Navigator.pop(context, text.text.trim()),
            child: const Text('Speichern'),
          ),
        ],
      ),
    );
    text.dispose();
    return result?.trim().isEmpty == true ? null : result;
  }

  Future<void> _renameOwnDevice(BuildContext context) async {
    final name = await _askName(
      context,
      'Dieses Gerät benennen',
      controller.deviceName,
    );
    if (name != null) await controller.setDeviceName(name);
  }

  Future<void> _renamePairedDevice(
    BuildContext context,
    String deviceId,
    String current,
  ) async {
    final name = await _askName(context, 'Verbundenes Gerät benennen', current);
    if (name != null) await controller.renamePairedDevice(deviceId, name);
  }
}

class _SettingsIntro extends StatelessWidget {
  const _SettingsIntro({
    required this.title,
    required this.description,
    required this.scope,
  });

  final String title;
  final String description;
  final FundusSettingScope scope;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 4),
              Text(description),
            ],
          ),
        ),
        const SizedBox(width: 12),
        _ScopeChip(scope: scope),
      ],
    ),
  );
}

class _ScopeChip extends StatelessWidget {
  const _ScopeChip({required this.scope});

  final FundusSettingScope scope;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: 'Geltungsbereich dieser Einstellung',
    child: Chip(
      avatar: Icon(_icon, size: 16),
      label: Text(_label),
      visualDensity: VisualDensity.compact,
    ),
  );

  String get _label => switch (scope) {
    FundusSettingScope.device => 'Gerät',
    FundusSettingScope.library => 'Bibliothek',
    FundusSettingScope.server => 'Server',
    FundusSettingScope.userProfile => 'Nutzerprofil',
  };

  IconData get _icon => switch (scope) {
    FundusSettingScope.device => Icons.devices_outlined,
    FundusSettingScope.library => Icons.video_library_outlined,
    FundusSettingScope.server => Icons.dns_outlined,
    FundusSettingScope.userProfile => Icons.person_outline,
  };
}
