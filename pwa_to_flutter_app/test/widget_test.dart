import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pwa_to_flutter_app/main.dart';

void main() {
  testWidgets('App load smoke test', (WidgetTester tester) async {
    // Build our app and trigger a frame.
    await tester.pumpWidget(const MaterialApp(home: MyApp()));

    // Basic check to see if the app builds without crashing.
    expect(find.byType(MyApp), findsOneWidget);
  });
}
