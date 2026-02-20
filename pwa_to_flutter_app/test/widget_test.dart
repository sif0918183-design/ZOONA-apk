import 'package:flutter_test/flutter_test.dart';
import 'package:tarhal_zoona_driver/main.dart';

void main() {
  test('App instantiation test', () {
    const app = DriverApp();
    expect(app, isA<DriverApp>());
  });
}
