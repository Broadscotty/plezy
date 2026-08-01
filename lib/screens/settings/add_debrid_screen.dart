import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:plezy/widgets/app_icon.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../../connection/connection.dart';
import '../../focus/focusable_text_field.dart';
import '../../i18n/strings.g.dart';
import '../../mixins/controller_disposer_mixin.dart';
import '../../profiles/active_profile_binder.dart';
import '../../profiles/active_profile_provider.dart';
import '../../profiles/profile.dart';
import '../../profiles/profile_connection.dart';
import '../../services/stremio/stremio_addon_client.dart';
import '../../utils/app_logger.dart';
import '../../widgets/focused_scroll_scaffold.dart';
import '../../widgets/loading_indicator_box.dart';
import 'async_form_state_mixin.dart';
import 'connection_persistence.dart';

class AddDebridScreen extends StatefulWidget {
  final Profile? targetProfile;
  final StremioAddonClient Function(String addonUrl)? _addonClientFactory;

  const AddDebridScreen({super.key, this.targetProfile, @visibleForTesting StremioAddonClient Function(String)? addonClientFactory})
    : _addonClientFactory = addonClientFactory;

  @override
  State<AddDebridScreen> createState() => _AddDebridScreenState();
}

class _AddDebridScreenState extends State<AddDebridScreen> with AsyncFormStateMixin, ControllerDisposerMixin {
  late final _addonUrlController = createTextEditingController();
  final _addonUrlFocus = FocusNode(debugLabel: 'AddDebrid:AddonUrl');
  final _formKey = GlobalKey<FormState>();
  String? _statusText;

  void _setStatus(String msg) {
    appLogger.i('AddDebrid: $msg');
    if (!mounted) return;
    setState(() => _statusText = msg);
  }

  @override
  void dispose() {
    _addonUrlFocus.dispose();
    super.dispose();
  }

  void _onPointerDown(PointerDownEvent event) {
    _setStatus('POINTER DOWN at (${event.position.dx.toStringAsFixed(0)}, ${event.position.dy.toStringAsFixed(0)})');
  }

  Future<void> _addServer() async {
    _setStatus('step: tapped, validating...');
    if (!(_formKey.currentState?.validate() ?? false)) {
      _setStatus('step: validation FAILED');
      return;
    }
    _setStatus('step: validation passed, creating client...');
    final addonUrl = _addonUrlController.text.trim();

    setBusy(true);
    setErrorText(null);
    try {
      final client = widget._addonClientFactory?.call(addonUrl) ?? StremioAddonClient(addonUrl: addonUrl);
      try {
        // The manifest is only used for the display name. Addon backends
        // (Torrentio in particular) flap under load and can exceed
        // Cloudflare's origin timeout (HTTP 522), which previously made the
        // whole add fail. Best-effort: try briefly, and if unreachable, add
        // the connection anyway with a name derived from the URL. Health is
        // probed separately and never gates the add.
        String addonName;
        try {
          _setStatus('step: fetching manifest from $addonUrl...');
          final manifest = await client.fetchManifest().timeout(const Duration(seconds: 10));
          addonName = manifest['name'] as String? ?? _friendlyAddonName(addonUrl);
          _setStatus('step: manifest OK: $addonName');
        } catch (e) {
          appLogger.w('Stremio: manifest unreachable during add, continuing anyway: $e');
          addonName = _friendlyAddonName(addonUrl);
          _setStatus('step: manifest unreachable, adding anyway as "$addonName"');
        }

        final connection = DebridConnection(
          id: const Uuid().v4(),
          addonUrl: addonUrl,
          addonName: addonName,
          realDebridApiToken: '',
          createdAt: DateTime.now(),
        );

        if (!mounted) return;
        _setStatus('step: persisting connection...');
        await _persistAndExit(connection);
        _setStatus('step: persist done');
      } finally {
        client.close();
      }
    } catch (e) {
      _setStatus('step: ERROR: $e');
      appLogger.e("Add debrid server failed", error: e);
      if (mounted) {
        setErrorText(t.addServer.couldNotReachServer(error: e.toString()));
      }
    } finally {
      if (mounted) setBusy(false);
    }
  }

  /// Derive a readable addon name from its URL host when the manifest can't
  /// be fetched (addon unreachable). "torrentio.strem.fun" -> "Torrentio".
  String _friendlyAddonName(String url) {
    final host = Uri.tryParse(url)?.host;
    if (host == null || host.isEmpty) return url;
    final first = host.split('.').first;
    if (first.isEmpty) return host;
    return first[0].toUpperCase() + first.substring(1);
  }

  Future<void> _persistAndExit(DebridConnection connection) async {
    if (!mounted) return;
    final activeProvider = context.read<ActiveProfileProvider>();
    await activeProvider.initialize();
    if (!mounted) return;
    final targetProfile = widget.targetProfile;
    final boundProfile = targetProfile ?? activeProvider.active;
    if (boundProfile == null) {
      setErrorText(t.messages.noProfilesAvailable);
      return;
    }

    await persistAndBindConnection(
      context: context,
      connection: connection,
      bindToProfile: ProfileConnection(
        profileId: boundProfile.id,
        connectionId: connection.id,
        userIdentifier: connection.id,
        tokenAcquiredAt: DateTime.now(),
      ),
      addToManager: null,
    );

    final boundToActive = boundProfile.id == activeProvider.activeId;
    if (!mounted) return;
    if (boundToActive) {
      await context.read<ActiveProfileBinder>().rebindIfActive(boundProfile.id);
    }

    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FocusedScrollScaffold(
      title: Text(t.addServer.addDebridTitle),
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.all(16),
          sliver: SliverToBoxAdapter(
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  FocusableTextFormField(
                    controller: _addonUrlController,
                    focusNode: _addonUrlFocus,
                    autofocus: true,
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    enableSuggestions: false,
                    enabled: !busy,
                    textInputAction: TextInputAction.done,
                    onFieldSubmitted: busy ? null : (_) => _addServer(),
                    decoration: InputDecoration(
                      labelText: t.addServer.debridAddonUrl,
                      hintText: 'https://torrentio.strem.fun',
                      helperText: t.addServer.debridAddonUrlHelper,
                      prefixIcon: const AppIcon(Symbols.extension_rounded, fill: 1),
                    ),
                    validator: (v) => v == null || v.trim().isEmpty ? t.addServer.required : null,
                  ),
                  const SizedBox(height: 16),
                  // Listener: raw pointer events fire BEFORE gesture arena /
                  // keyboard dismiss / focus logic. If this shows "POINTER
                  // DOWN", the tap physically reached the button region.
                  Listener(
                    onPointerDown: _onPointerDown,
                    behavior: HitTestBehavior.translucent,
                    child: GestureDetector(
                      onTap: busy ? null : _addServer,
                      behavior: HitTestBehavior.opaque,
                      child: FilledButton.icon(
                        onPressed: busy ? null : _addServer,
                        icon: busy ? const LoadingIndicatorBox() : const AppIcon(Symbols.add_link_rounded, fill: 1),
                        label: Text(t.addServer.addDebridServer),
                      ),
                    ),
                  ),
                  if (_statusText != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      _statusText!,
                      style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.primary),
                    ),
                  ],
                  ...buildInlineError(theme),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}
