// Reproducible, offline connection-start / idle workload. No user data or sockets.
import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';
import 'package:qq_bot_manager/agent/controller.dart';
import 'package:qq_bot_manager/agent/extensions.dart';
import 'package:qq_bot_manager/agent/models.dart';
import 'package:qq_bot_manager/agent/onebot.dart';
import 'package:qq_bot_manager/agent/package_bundle.dart';
import 'package:qq_bot_manager/agent/store.dart';

class ProbeStore extends AgentStore {
  final reads = <String, int>{};
  bool measuring = false;
  ProbeStore() : super.memory();
  @override
  Json? get(String key) {
    if (measuring) {
      reads.update(key.split(':').first, (n) => n + 1, ifAbsent: () => 1);
    }
    return super.get(key);
  }
}

class ProbeTransport extends AgentTransport {
  bool online = false;
  @override
  bool get connected => online;
  @override
  String get status => online ? '已连接' : '未连接';
  @override
  String get nickname => '离线性能测试';
  @override
  Future<void> start() async {
    online = true;
    onState?.call();
  }

  @override
  Future<void> stop() async {
    online = false;
    onState?.call();
  }

  @override
  Future<dynamic> call(String action, [Json params = const {}]) async => {};
}

double? cpuMilliseconds() {
  if (!Platform.isWindows) return null;
  final kernel = DynamicLibrary.open('kernel32.dll');
  final current = kernel
      .lookupFunction<Pointer<Void> Function(), Pointer<Void> Function()>(
        'GetCurrentProcess',
      );
  final times = kernel
      .lookupFunction<
        Int32 Function(
          Pointer<Void>,
          Pointer<Uint64>,
          Pointer<Uint64>,
          Pointer<Uint64>,
          Pointer<Uint64>,
        ),
        int Function(
          Pointer<Void>,
          Pointer<Uint64>,
          Pointer<Uint64>,
          Pointer<Uint64>,
          Pointer<Uint64>,
        )
      >('GetProcessTimes');
  final data = calloc<Uint64>(4);
  try {
    if (times(current(), data, data + 1, data + 2, data + 3) == 0) return null;
    return (data[2] + data[3]) / 10000;
  } finally {
    calloc.free(data);
  }
}

Future<void> main(List<String> args) async {
  final count = args.isEmpty ? 6 : int.parse(args.first), store = ProbeStore();
  final agent = AgentController(
    store: store,
    transportFactory: (_) => ProbeTransport(),
  );
  try {
    await agent.initialize();
    final ids = <String>[];
    for (var i = 0; i < count; i++) {
      final id = 'perf-$i';
      ids.add(id);
      const source =
          "let api;export function setup(a){api=a;}export function activate(){setInterval(()=>{},60000);api.log('probe-ready');}export const hooks={'before-llm-messages':()=>{}};";
      final manifest = AgentPackageBundle(
        {'id': id, 'name': id, 'apiVersion': 1},
        {
          'index.js': base64Encode(utf8.encode(source)),
          'asset.bin': base64Encode(List<int>.filled(128 * 1024, 42)),
        },
        'plugin',
        'plugin.json',
      ).normalized();
      await agent.saveExtension(AgentExtension(manifest, enabled: true));
    }
    final start = Stopwatch()..start();
    await agent.saveConnection(
      AgentConnection(
        id: 'probe',
        name: '离线性能测试',
        selfId: '10001',
        pluginIds: ids,
      ),
    );
    await agent.connect('probe');
    for (
      var i = 0;
      i < 1000 &&
          agent.logs
                  .where(
                    (line) => text(line['message']).contains('probe-ready'),
                  )
                  .length <
              count;
      i++
    ) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    final startup = start.elapsedMilliseconds;
    await Future<void>.delayed(const Duration(milliseconds: 300));
    store.measuring = true;
    final elapsed = Stopwatch()..start(), cpu = cpuMilliseconds();
    var last = 0, maxGap = 0, ticks = 0;
    final pulse = Timer.periodic(const Duration(milliseconds: 16), (_) {
      final now = elapsed.elapsedMilliseconds;
      final gap = now - last;
      if (gap > maxGap) maxGap = gap;
      last = now;
      ticks++;
    });
    await Future<void>.delayed(const Duration(seconds: 3));
    pulse.cancel();
    store.measuring = false;
    final endCpu = cpuMilliseconds();
    stdout.writeln(
      jsonEncode({
        'workers': count,
        'startupMs': startup,
        'sampleMs': elapsed.elapsedMilliseconds,
        'mainLoopTicks': ticks,
        'maxMainLoopGapMs': maxGap,
        'storeReads': store.reads,
        'cpuMs': cpu == null || endCpu == null ? null : endCpu - cpu,
        'rssBytes': ProcessInfo.currentRss,
      }),
    );
  } finally {
    await agent.shutdown();
    agent.dispose();
  }
}
