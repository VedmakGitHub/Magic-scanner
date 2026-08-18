import 'package:flutter/material.dart';

import 'legal_strings.dart';

/// Legal & attribution screen (Section 9). Reachable from Settings.
class LegalScreen extends StatelessWidget {
  const LegalScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Legal & attribution')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: const [
          _Section(title: 'Fan Content Policy', body: LegalStrings.fanContent),
          _Section(title: 'Scryfall', body: LegalStrings.scryfall),
          _Section(title: 'Prices', body: LegalStrings.prices),
          _Section(title: 'About', body: LegalStrings.about),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  final String title;
  final String body;
  const _Section({required this.title, required this.body});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(body, style: Theme.of(context).textTheme.bodyMedium),
        ],
      ),
    );
  }
}
