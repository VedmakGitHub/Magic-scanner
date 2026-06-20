import 'package:flutter/material.dart';

import '../recognition/recognition_service.dart' show kCardAspect;

/// Fraction of the preview width the guide frame occupies. MUST match the crop
/// in recognition_service.cropToCardGuide so the hashed pixels are what the user
/// frames (Section 6).
const double kGuideWidthFraction = 0.86;
const double kGuideMaxHeightFraction = 0.94;

/// Darkens everything outside a centered card-shaped frame and draws the guide.
class GuideOverlay extends StatelessWidget {
  const GuideOverlay({super.key});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return CustomPaint(
          size: Size(constraints.maxWidth, constraints.maxHeight),
          painter: _GuidePainter(),
        );
      },
    );
  }
}

Rect cardGuideRect(Size size) {
  var w = size.width * kGuideWidthFraction;
  var h = w / kCardAspect;
  if (h > size.height * kGuideMaxHeightFraction) {
    h = size.height * kGuideMaxHeightFraction;
    w = h * kCardAspect;
  }
  final left = (size.width - w) / 2;
  final top = (size.height - h) / 2;
  return Rect.fromLTWH(left, top, w, h);
}

class _GuidePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final rect = cardGuideRect(size);
    final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(12));

    // Dim outside the frame.
    final overlay = Path()..addRect(Offset.zero & size);
    final hole = Path()..addRRect(rrect);
    final dimmed = Path.combine(PathOperation.difference, overlay, hole);
    canvas.drawPath(dimmed, Paint()..color = Colors.black54);

    // Frame border.
    canvas.drawRRect(
      rrect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..color = Colors.white,
    );

    // Corner accents.
    final corner = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..color = Colors.tealAccent;
    const len = 26.0;
    void cornerLines(Offset o, Offset dx, Offset dy) {
      canvas.drawLine(o, o + dx, corner);
      canvas.drawLine(o, o + dy, corner);
    }

    cornerLines(rect.topLeft, const Offset(len, 0), const Offset(0, len));
    cornerLines(rect.topRight, const Offset(-len, 0), const Offset(0, len));
    cornerLines(rect.bottomLeft, const Offset(len, 0), const Offset(0, -len));
    cornerLines(rect.bottomRight, const Offset(-len, 0), const Offset(0, -len));
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
