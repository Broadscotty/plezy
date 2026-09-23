import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../focus/focusable_button.dart';
import '../../services/credential_vault.dart';
import '../../services/settings_service.dart';
import '../../services/stremio/stremio_api_client.dart';
import '../../services/stremio/stremio_sync_service.dart';
import '../../utils/app_logger.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/focused_scroll_scaffold.dart';
import '../../widgets/focusable_list_tile.dart';
import '../../widgets/loading_indicator_box.dart';
import '../../widgets/settings_section.dart';

/// Connect a Stremio account via the official device-link flow and control
/// the watch-progress sync toggle.
///
/// Flow: create a link code at `link.stremio.com`, open the approval URL in
/// the browser, poll `read` until the user approves, then vault the returned
/// auth key. Strings are intentionally hardcoded for this feature branch —
/// the slang i18n pipeline needs regeneration, which is out of scope here.
class StremioSettingsScreen extends StatefulWidget {
  const StremioSettingsScreen({super.key});

  @override
  State<StremioSettingsScreen> createState() => _StremioSettingsScreenState();
}

class _StremioSettingsScreenState extends State<StremioSettingsScreen> {
  static const Duration _pollInterval = Duration(seconds: 2);
  static const Duration _linkLifetime = Duration(minutes: 10);

  bool _busy = false;
  bool _disposed = false;
  bool _enabled = true;
  bool _connected = false;
  StremioLinkCode? _pending;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  Future<void> _load() async {
    final settings = await SettingsService.getInstance();
    if (_disposed) return;
    setState(() {
      _enabled = settings.read(SettingsService.enableStremioSync);
      _connected = settings.read(SettingsService.stremioAuthKey) != null;
    });
  }

  Future<void> _connect() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final client = StremioApiClient();
    try {
      final code = await client.createLink();
      if (_disposed) return;
      setState(() => _pending = code);
      // Best effort — the code itself is always shown on screen as a fallback.
      await launchUrl(Uri.parse(code.link), mode: LaunchMode.externalApplication);
    } catch (e) {
      appLogger.w('Stremio: link creation failed', error: e);
      if (_disposed) return;
      setState(() => _error = 'Could not reach Stremio: $e');
      return;
    } finally {
      if (!_disposed) setState(() => _busy = false);
    }
    await _pollForApproval(client);
  }

  Future<void> _pollForApproval(StremioApiClient client) async {
    final code = _pending;
    if (code == null) return;
    final deadline = DateTime.now().add(_linkLifetime);
    while (!_disposed && _pending != null && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(_pollInterval);
      if (_disposed || _pending == null) return;
      final authKey = await client.readLink(code.code);
      if (authKey == null) continue;
      final valid = await client.validateAuthKey(authKey);
      if (!valid) {
        if (_disposed) return;
        setState(() {
          _pending = null;
          _error = 'Stremio rejected the authorization key. Try again.';
        });
        return;
      }
      final protected = await CredentialVault.protect(authKey);
      await SettingsService.instance.write(SettingsService.stremioAuthKey, protected);
      StremioSyncService.instance.invalidateCachedAuth();
      if (_disposed) return;
      setState(() {
        _pending = null;
        _connected = true;
        _error = null;
      });
      return;
    }
    if (_disposed || _pending == null) return;
    setState(() {
      _pending = null;
      _error = 'The link expired before it was approved. Try again.';
    });
  }

  void _cancelPending() {
    setState(() => _pending = null);
  }

  Future<void> _toggleEnabled(bool value) async {
    setState(() => _enabled = value);
    await SettingsService.instance.write(SettingsService.enableStremioSync, value);
    StremioSyncService.instance.invalidateCachedAuth();
  }

  Future<void> _disconnect() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Disconnect Stremio?'),
        content: const Text('Watch progress will stop syncing to your Stremio account.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text('Disconnect', style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
        ],
      ),
    );
    if (confirmed != true || _disposed) return;
    await SettingsService.instance.write(SettingsService.stremioAuthKey, null);
    StremioSyncService.instance.invalidateCachedAuth();
    if (_disposed) return;
    setState(() => _connected = false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FocusedScrollScaffold(
      title: const Text('Stremio'),
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.only(top: 8, bottom: 24),
          sliver: SliverList(
            delegate: SliverChildListDelegate([
              SettingsGroup(
                title: 'Account',
                children: [
                  FocusableListTile(
                    leading: const AppIcon(Symbols.live_tv_rounded),
                    title: Text(_connected ? 'Connected' : 'Not connected'),
                    subtitle: Text(
                      _connected
                          ? (_enabled
                                ? 'Watch progress syncs to your Stremio Continue Watching'
                                : 'Sync is paused')
                          : 'Sync your plezy watch history into Stremio',
                    ),
                    trailing: _connected
                        ? Switch(value: _enabled, onChanged: _busy ? null : _toggleEnabled)
                        : null,
                  ),
                ],
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                  child: Text(_error!, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.error)),
                ),
              if (!_connected && _pending == null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                  child: FocusableButton(
                    onPressed: _busy ? null : _connect,
                    child: FilledButton.icon(
                      onPressed: _busy ? null : _connect,
                      icon: _busy ? const LoadingIndicatorBox() : const AppIcon(Symbols.login_rounded),
                      label: const Text('Connect Stremio'),
                    ),
                  ),
                ),
              if (!_connected && _pending != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Approve in your browser', style: theme.textTheme.titleSmall),
                      const SizedBox(height: 8),
                      SelectableText(_pending!.link, style: theme.textTheme.bodyMedium),
                      const SizedBox(height: 8),
                      Text('Code: ${_pending!.code}', style: theme.textTheme.titleMedium),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          const LoadingIndicatorBox(),
                          const SizedBox(width: 12),
                          Text('Waiting for approval…', style: theme.textTheme.bodyMedium),
                        ],
                      ),
                      const SizedBox(height: 12),
                      FocusableButton(
                        onPressed: _busy ? null : () => launchUrl(Uri.parse(_pending!.link), mode: LaunchMode.externalApplication),
                        child: OutlinedButton(
                          onPressed: _busy ? null : () => launchUrl(Uri.parse(_pending!.link), mode: LaunchMode.externalApplication),
                          child: const Text('Open link again'),
                        ),
                      ),
                      FocusableButton(
                        onPressed: _cancelPending,
                        child: TextButton(onPressed: _cancelPending, child: const Text('Cancel')),
                      ),
                    ],
                  ),
                ),
              if (_connected)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                  child: FocusableButton(
                    onPressed: _busy ? null : _disconnect,
                    child: OutlinedButton(onPressed: _busy ? null : _disconnect, child: const Text('Disconnect')),
                  ),
                ),
            ]),
          ),
        ),
      ],
    );
  }
}
