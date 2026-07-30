import 'dart:async';

import 'package:flutter/material.dart';
import 'package:plezy/widgets/app_icon.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../../connection/connection.dart';
import '../../focus/focusable_button.dart';
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

/// Simple two-field form to add a debrid server: a Stremio addon URL and a
/// Real-Debrid API token. Unlike Plex/Jellyfin there's no live-server
/// authentication handshake -- "sign in" here just means confirming the
/// addon's manifest is reachable, then persisting the connection.
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
  late final _tokenController = createTextEditingController();
  final _addonUrlFocus = FocusNode(debugLabel: 'AddDebrid:AddonUrl');
  final _tokenFocus = FocusNode(debugLabel: 'AddDebrid:Token');
  final _addFocus = FocusNode(debugLabel: 'AddDebrid:Add');
  final _formKey = GlobalKey<FormState>();

  @override
  void dispose() {
    _addonUrlFocus.dispose();
    _tokenFocus.dispose();
    _addFocus.dispose();
    super.dispose();
  }

  Future<void> _addServer() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final addonUrl = _addonUrlController.text.trim();
    final token = _tokenController.text.trim();

    await runAsync<void>(
      () async {
        final client = widget._addonClientFactory?.call(addonUrl) ?? StremioAddonClient(addonUrl: addonUrl);
        final manifest = await client.fetchManifest();
        client.close();
        final addonName = manifest['name'] as String? ?? addonUrl;

        final connection = DebridConnection(
          id: const Uuid().v4(),
          addonUrl: addonUrl,
          addonName: addonName,
          realDebridApiToken: token,
          createdAt: DateTime.now(),
        );

        if (!mounted) return;
        await _persistAndExit(connection);
      },
      errorMapper: (e) {
        appLogger.e('Add debrid server failed', error: e);
        return t.addServer.couldNotReachServer(error: e.toString());
      },
    );
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
                crossAxisAlignment: .stretch,
                children: [
                  FocusableTextFormField(
                    controller: _addonUrlController,
                    focusNode: _addonUrlFocus,
                    autofocus: true,
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    enableSuggestions: false,
                    enabled: !busy,
                    onNavigateDown: () => _tokenFocus.requestFocus(),
                    textInputAction: TextInputAction.next,
                    onFieldSubmitted: busy ? null : (_) => _tokenFocus.requestFocus(),
                    decoration: InputDecoration(
                      labelText: t.addServer.debridAddonUrl,
                      hintText: 'https://torrentio.strem.fun',
                      helperText: t.addServer.debridAddonUrlHelper,
                      prefixIcon: const AppIcon(Symbols.extension_rounded, fill: 1),
                    ),
                    validator: (v) => v == null || v.trim().isEmpty ? t.addServer.required : null,
                  ),
                  const SizedBox(height: 12),
                  FocusableTextFormField(
                    controller: _tokenController,
                    focusNode: _tokenFocus,
                    obscureText: true,
                    autocorrect: false,
                    enableSuggestions: false,
                    enabled: !busy,
                    onNavigateUp: () => _addonUrlFocus.requestFocus(),
                    textInputAction: TextInputAction.done,
                    onFieldSubmitted: busy ? null : (_) => _addServer(),
                    decoration: InputDecoration(
                      labelText: t.addServer.debridApiToken,
                      helperText: t.addServer.debridApiTokenHelper,
                      prefixIcon: const AppIcon(Symbols.key_rounded, fill: 1),
                    ),
                    validator: (v) => v == null || v.trim().isEmpty ? t.addServer.required : null,
                  ),
                  const SizedBox(height: 16),
                  FocusableButton(
                    focusNode: _addFocus,
                    useBackgroundFocus: true,
                    onNavigateUp: () => _tokenFocus.requestFocus(),
                    onPressed: busy ? null : _addServer,
                    child: FilledButton.icon(
                      onPressed: busy ? null : _addServer,
                      icon: busy ? const LoadingIndicatorBox() : const AppIcon(Symbols.add_link_rounded, fill: 1),
                      label: Text(t.addServer.addDebridServer),
                    ),
                  ),
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
