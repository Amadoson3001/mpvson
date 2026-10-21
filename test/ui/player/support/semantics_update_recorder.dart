import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';

class RecordingTestBinding extends AutomatedTestWidgetsFlutterBinding {
  @override
  ui.SemanticsUpdateBuilder createSemanticsUpdateBuilder() =>
      _RecordingBuilder();
}

class SemanticsUpdateRecorder {
  static final instance = SemanticsUpdateRecorder();
  final Map<int, List<int>> children = {};
  final List<String> violations = [];
  int updateCount = 0;

  void reset() {
    children.clear();
    violations.clear();
    updateCount = 0;
  }

  void commit(Map<int, List<int>> updates, Map<int, String> labels) {
    updateCount++;
    children.addAll(updates);
    final reachable = <int>{};
    void visit(int id) {
      if (!reachable.add(id)) return;
      for (final child in children[id] ?? const <int>[]) {
        visit(child);
      }
    }

    visit(0);
    for (final id in updates.keys) {
      if (!reachable.contains(id)) {
        violations.add(
          'update $updateCount: orphan $id, label=${labels[id]}, children=${updates[id]}',
        );
      }
    }
    children.removeWhere((id, _) => !reachable.contains(id));
  }
}

class _RecordingBuilder extends Fake implements ui.SemanticsUpdateBuilder {
  final _inner = ui.SemanticsUpdateBuilder();
  final Map<int, List<int>> _updates = {};
  final Map<int, String> _labels = {};

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #updateNode) {
      final values = invocation.namedArguments;
      final id = values[#id] as int;
      _updates[id] = List<int>.from(
        values[#childrenInTraversalOrder] as List<int>,
      );
      _labels[id] = '${values[#label]}';
      Function.apply(_inner.updateNode, invocation.positionalArguments, values);
      return null;
    }
    if (invocation.memberName == #updateCustomAction) {
      Function.apply(
        _inner.updateCustomAction,
        invocation.positionalArguments,
        invocation.namedArguments,
      );
      return null;
    }
    return super.noSuchMethod(invocation);
  }

  @override
  ui.SemanticsUpdate build() {
    SemanticsUpdateRecorder.instance.commit(_updates, _labels);
    return _inner.build();
  }
}
