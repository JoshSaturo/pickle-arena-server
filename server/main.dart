import 'dart:io';

import 'relay.dart';
import 'records.dart';

Future<void> main() async {
  final relay = ArenaRelay(
    records: SupabaseRecords.fromEnvironment(),
    maxRooms: int.parse(Platform.environment['MAX_ROOMS'] ?? '100'),
  );
  await relay.start(port: int.parse(Platform.environment['PORT'] ?? '8080'));
  stdout.writeln('Pickle Arena relay listening on port ${relay.port}');
  // Rooms live in memory; a shutdown cleanly ends any active matches.
  ProcessSignal.sigint.watch().listen((_) async {
    await relay.close();
    exit(0);
  });
  if (!Platform.isWindows) {
    ProcessSignal.sigterm.watch().listen((_) async {
      await relay.close();
      exit(0);
    });
  }
}
