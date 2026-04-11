import 'package:flutter_test/flutter_test.dart';
import 'package:matjar_zoona/main.dart';

void main() {
  test('App instantiation test', () {
    const app = ZoonaApp();
    expect(app, isA<ZoonaApp>());
  });
}
