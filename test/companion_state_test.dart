import 'package:ilonatv/companion/state.dart';
import 'package:ilonatv/ui/qr_code.dart';
import 'package:ilonatv_protocol/ilonatv_protocol.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('listeners fire on a change and not on the same value', () {
    final c = CompanionState();
    var n = 0;
    c.addListener(() => n++);
    expect(c.inFront, isTrue);
    c.setStep(SetupStep.tmdb);
    c.setStep(SetupStep.tmdb);
    expect(n, 1);
    c.setStep(null);
    expect(n, 2);
    c.setInFront(true);
    expect(n, 2);
    c.setInFront(false);
    expect(n, 3);
    expect(c.inFront, isFalse);
  });

  testWidgets('the QR paints a square of its size', (tester) async {
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: Center(child: QrCode('http://10.0.0.5:8642/#s=abc', size: 180)),
      ),
    );
    expect(tester.getSize(find.byType(QrCode)), const Size(180, 180));
  });
}
