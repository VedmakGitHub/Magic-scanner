import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models.dart';
import '../recognition/matcher.dart';
import '../recognition/recognition_service.dart';
import '../ui/widgets.dart';
import 'version_picker.dart';

/// Candidate confirmation sheet — top-5 thumbnails; pick or rescan (Section 6, 8.3).
Future<void> showCandidateSheet(
  BuildContext context,
  WidgetRef ref,
  RecognitionResult result,
) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => _CandidateSheet(result: result),
  );
}

class _CandidateSheet extends ConsumerWidget {
  final RecognitionResult result;
  const _CandidateSheet({required this.result});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final candidates =
        result.candidates.where((c) => c.printing != null).toList();
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      maxChildSize: 0.92,
      builder: (context, scrollController) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _headline(),
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                ],
              ),
            ),
            if (result.confidence == MatchConfidence.weak)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: Text(
                  'No confident match. Pick the right card or rescan with better '
                  'framing and lighting.',
                  style: TextStyle(color: Colors.orangeAccent, fontSize: 12),
                ),
              ),
            Expanded(
              child: candidates.isEmpty
                  ? const Center(child: Text('No candidates found. Try rescanning.'))
                  : ListView.builder(
                      controller: scrollController,
                      itemCount: candidates.length,
                      itemBuilder: (context, i) {
                        final c = candidates[i];
                        final preselect = i == 0 && result.shouldPreselect;
                        return _CandidateTile(
                          candidate: c,
                          preselected: preselect,
                          onTap: () => _onPick(context, ref, c),
                        );
                      },
                    ),
            ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: OutlinedButton.icon(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.refresh),
                  label: const Text('None of these — rescan'),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  String _headline() {
    switch (result.confidence) {
      case MatchConfidence.strong:
        return 'Is this your card?';
      case MatchConfidence.ambiguous:
        return 'A few close matches — pick one';
      case MatchConfidence.weak:
        return 'Possible matches';
    }
  }

  Future<void> _onPick(BuildContext context, WidgetRef ref, Candidate c) async {
    // Resolve which exact printing via the version picker, then add to collection.
    final added = await showVersionPicker(context, ref, c);
    if (added == true && context.mounted) {
      Navigator.of(context).pop(); // close the candidate sheet
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Added to your collection')),
      );
    }
  }
}

class _CandidateTile extends StatelessWidget {
  final Candidate candidate;
  final bool preselected;
  final VoidCallback onTap;

  const _CandidateTile({
    required this.candidate,
    required this.preselected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final p = candidate.printing!;
    return ListTile(
      onTap: onTap,
      leading: SizedBox(
        width: 52,
        height: 73,
        child: CardImage(printing: p, thumbnail: true),
      ),
      title: Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        '${p.setName} · dist ${candidate.distance}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: preselected
          ? const Icon(Icons.star, color: Colors.tealAccent)
          : const Icon(Icons.chevron_right),
      tileColor: preselected ? Colors.tealAccent.withValues(alpha: 0.08) : null,
    );
  }
}
