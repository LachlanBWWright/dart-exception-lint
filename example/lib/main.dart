import 'package:third_party_stub/third_party_stub.dart';

String? loadName() => 'example';

void fail() {
  throw Exception('manual throw');
}

void main() {
  final client = DangerousClient.named();
  print(loadName()!);
  client.fetch();
  fail();
}
