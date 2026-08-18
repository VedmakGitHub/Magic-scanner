import 'package:flutter/material.dart';

/// The floating right-edge control pill on the scan screen: a saved-count badge
/// (opens the session sheet), a flash/torch toggle, and a settings button.
class ScanControlPill extends StatelessWidget {
  final int sessionCount;
  final bool flashOn;
  final VoidCallback onSession;
  final VoidCallback onFlash;
  final VoidCallback onSettings;

  const ScanControlPill({
    super.key,
    required this.sessionCount,
    required this.flashOn,
    required this.onSession,
    required this.onFlash,
    required this.onSettings,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(28),
      ),
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _badged(
            count: sessionCount,
            child: IconButton(
              tooltip: 'Scanned cards',
              icon: const Icon(Icons.collections_bookmark_outlined,
                  color: Colors.white),
              onPressed: onSession,
            ),
          ),
          IconButton(
            tooltip: flashOn ? 'Flash on' : 'Flash off',
            icon: Icon(flashOn ? Icons.flash_on : Icons.flash_off,
                color: flashOn ? Colors.amber : Colors.white),
            onPressed: onFlash,
          ),
          IconButton(
            tooltip: 'Scan settings',
            icon: const Icon(Icons.settings, color: Colors.white),
            onPressed: onSettings,
          ),
        ],
      ),
    );
  }

  Widget _badged({required int count, required Widget child}) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        child,
        if (count > 0)
          Positioned(
            right: 2,
            top: 2,
            child: Container(
              padding: const EdgeInsets.all(4),
              constraints: const BoxConstraints(minWidth: 18, minHeight: 18),
              decoration: const BoxDecoration(
                color: Colors.amber,
                shape: BoxShape.circle,
              ),
              child: Text(
                '$count',
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: Colors.black,
                    fontSize: 10,
                    fontWeight: FontWeight.bold),
              ),
            ),
          ),
      ],
    );
  }
}
