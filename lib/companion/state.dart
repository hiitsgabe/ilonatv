import 'package:elimor_protocol/elimor_protocol.dart';
import 'package:flutter/foundation.dart';

class CompanionState extends ChangeNotifier {
  SetupStep? step;
  bool inFront = true;

  void setStep(SetupStep? v) {
    if (v == step) return;
    step = v;
    notifyListeners();
  }

  void setInFront(bool v) {
    if (v == inFront) return;
    inFront = v;
    notifyListeners();
  }
}

final companionState = CompanionState();
