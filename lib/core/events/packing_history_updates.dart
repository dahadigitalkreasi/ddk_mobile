import 'package:flutter/foundation.dart';

final ValueNotifier<int> packingHistoryUpdates = ValueNotifier<int>(0);

void notifyPackingHistoryUpdated() {
  packingHistoryUpdates.value++;
}
