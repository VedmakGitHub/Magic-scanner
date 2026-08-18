import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/bundle_loader.dart';
import '../data/config.dart';
import '../data/providers.dart';
import '../legal/legal_screen.dart';
import '../legal/legal_strings.dart';

/// Settings: check for card-data update, legal notices, app + bundle version
/// (Section 8.7).
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(bundleControllerProvider);
    final busy = status.phase == BundlePhase.checking ||
        status.phase == BundlePhase.downloading ||
        status.phase == BundlePhase.unpacking ||
        status.phase == BundlePhase.verifying;

    return ListView(
      children: [
        const _Header('Card data'),
        ListTile(
          title: const Text('Bundle version'),
          subtitle: Text(status.bundleVersion ?? 'unknown'),
        ),
        ListTile(
          title: const Text('Check for card-data update'),
          subtitle: Text(busy ? status.message : 'Re-fetch the latest bundle'),
          trailing: busy
              ? const SizedBox(
                  width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.refresh),
          onTap: busy
              ? null
              : () async {
                  await ref.read(bundleControllerProvider.notifier).checkForUpdate();
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(ref.read(bundleControllerProvider).message)),
                    );
                  }
                },
        ),
        const Divider(),
        const _Header('Legal'),
        ListTile(
          leading: const Icon(Icons.gavel_outlined),
          title: const Text('Legal & attribution'),
          subtitle: const Text('Fan Content Policy, Scryfall, prices'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const LegalScreen()),
          ),
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Text(
            LegalStrings.fanContent,
            style: TextStyle(fontSize: 11, color: Colors.white54),
          ),
        ),
        const Divider(),
        const _Header('About'),
        const ListTile(
          title: Text('App version'),
          subtitle: Text('${AppConfig.appName} ${AppConfig.appVersion}'),
        ),
      ],
    );
  }
}

class _Header extends StatelessWidget {
  final String text;
  const _Header(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        text.toUpperCase(),
        style: Theme.of(context)
            .textTheme
            .labelSmall
            ?.copyWith(color: Theme.of(context).colorScheme.primary),
      ),
    );
  }
}
