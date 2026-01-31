import 'package:flutter_test/flutter_test.dart';
import 'package:pwa_to_flutter_app/main.dart';

void main() {
  test('MyApp instantiation test', () {
    const app = MyApp();
    expect(app, isA<MyApp>());
  });
}
