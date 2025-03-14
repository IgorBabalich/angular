import 'package:test/test.dart';
import 'package:ngdart/src/common/pipes/uppercase_pipe.dart';

void main() {
  group('UpperCasePipe', () {
    late String upper;
    late String lower;
    late UpperCasePipe pipe;
    setUp(() {
      lower = 'something';
      upper = 'SOMETHING';
      pipe = UpperCasePipe();
    });
    group('transform', () {
      test('should return uppercase', () {
        var val = pipe.transform(lower);
        expect(val, upper);
      });
      test('should uppercase when there is a new value', () {
        var val = pipe.transform(lower);
        expect(val, upper);
        var val2 = pipe.transform('wat');
        expect(val2, 'WAT');
      });
    });
  });
}
