class Interpreter {
  Interpreter._();

  static Future<Interpreter> fromAsset(String asset) async {
    throw UnsupportedError('tflite_flutter is not supported on web.');
  }

  void run(Object input, Object output) {
    throw UnsupportedError('tflite_flutter is not supported on web.');
  }
}
