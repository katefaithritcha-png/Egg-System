import 'package:flutter_test/flutter_test.dart';

import 'package:egg_system_flutter/main.dart';

void main() {
  testWidgets('boots converted egg system app', (WidgetTester tester) async {
    await tester.pumpWidget(const EggSystemBootstrap());
    await tester.pumpAndSettle();

    expect(find.text('SMARTSORT'), findsOneWidget);
    expect(find.text('SIGN IN'), findsOneWidget);
  });
}
