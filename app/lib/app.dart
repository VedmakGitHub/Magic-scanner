import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'camera/capture_screen.dart';
import 'collection/collection_screen.dart';
import 'data/bundle_loader.dart';
import 'data/providers.dart';
import 'legal/legal_strings.dart';
import 'settings/settings_screen.dart';
import 'ui/theme.dart';

class MtgScannerApp extends StatelessWidget {
  const MtgScannerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MTG Scanner',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      home: const RootGate(),
    );
  }
}

/// Gates the app on the bundle being ready (Section 8.1). Shows the first-launch
/// download/verify screen until a usable bundle exists, then the main shell.
class RootGate extends ConsumerWidget {
  const RootGate({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(bundleControllerProvider);
    if (status.isReady) return const HomeShell();
    return BundleSetupScreen(status: status);
  }
}

class BundleSetupScreen extends ConsumerWidget {
  final BundleStatus status;
  const BundleSetupScreen({super.key, required this.status});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isError = status.phase == BundlePhase.error;
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(isError ? Icons.cloud_off : Icons.style_outlined, size: 56),
              const SizedBox(height: 16),
              Text('MTG Scanner', style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 8),
              const Text(
                'One-time card-data download. After this the app works offline.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 28),
              if (!isError) ...[
                LinearProgressIndicator(
                  value: status.progress >= 0 ? status.progress : null,
                ),
                const SizedBox(height: 12),
                Text(
                  status.progress >= 0
                      ? '${status.message}  ${(status.progress * 100).toStringAsFixed(0)}%'
                      : status.message,
                  textAlign: TextAlign.center,
                ),
              ] else ...[
                Text(status.message, textAlign: TextAlign.center),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: () =>
                      ref.read(bundleControllerProvider.notifier).start(),
                  icon: const Icon(Icons.refresh),
                  label: const Text('Retry download'),
                ),
              ],
              const SizedBox(height: 32),
              Text(
                LegalStrings.fanContent,
                textAlign: TextAlign.center,
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: Colors.white54),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Bottom-nav shell: Scan / Collection / Settings (Section 8).
class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> {
  int _index = 0;

  static const _titles = ['Scan', 'Collection', 'Settings'];

  @override
  Widget build(BuildContext context) {
    // Keep the camera screen alive only while selected; rebuild others lazily.
    final body = switch (_index) {
      0 => const CaptureScreen(),
      1 => const CollectionScreen(),
      _ => const SettingsScreen(),
    };

    return Scaffold(
      appBar: _index == 0 ? null : AppBar(title: Text(_titles[_index])),
      extendBodyBehindAppBar: _index == 0,
      body: SafeArea(top: _index != 0, bottom: false, child: body),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(
              icon: Icon(Icons.camera_alt_outlined),
              selectedIcon: Icon(Icons.camera_alt),
              label: 'Scan'),
          NavigationDestination(
              icon: Icon(Icons.style_outlined),
              selectedIcon: Icon(Icons.style),
              label: 'Collection'),
          NavigationDestination(
              icon: Icon(Icons.settings_outlined),
              selectedIcon: Icon(Icons.settings),
              label: 'Settings'),
        ],
      ),
    );
  }
}
