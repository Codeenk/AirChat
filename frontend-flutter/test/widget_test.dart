import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:air_chat/main.dart';

void main() {
  testWidgets('AirChatApp smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: AirChatApp(),
      ),
    );
    expect(find.text('Air Chat'), findsOneWidget);
  });
}
