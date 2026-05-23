import 'package:third_party_stub/third_party_stub.dart';
import 'package:third_party_stub/third_party_stub.dart' as throwing;

Future<void> validateManualCoverage(DangerousClient client) async {
  dangerousTopLevel();
  DangerousClient.named();
  DangerousClient.load();
  client.fetch();
  throwing.dangerousTopLevel();

  try {
    dangerousTopLevel();
    await dangerousAsync();
    DangerousClient.load();
    client.fetch();
  } catch (_) {}

  try {
    dangerousTopLevel();
  } catch (_) {
    client.fetch();
  }

  try {
    DangerousClient.load();
  } finally {}
}
