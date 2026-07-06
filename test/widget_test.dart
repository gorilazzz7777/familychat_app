import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:familychat_app/main.dart';

void main() {
  testWidgets('App boots', (WidgetTester tester) async {
    await tester.pumpWidget(const ProviderScope(child: FamilyChatApp()));
    expect(find.text('Family Chat'), findsOneWidget);
  });
}
