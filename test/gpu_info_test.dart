import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/data/services/gpu_info_service.dart';
import 'package:mpvson/data/services/playback_statistics.dart';
import 'package:mpvson/domain/models/gpu_adapter.dart';
import 'package:mpvson/ui/player/views/playback_info_dialog.dart';

class _FakeGpuInfoService extends GpuInfoService {
  _FakeGpuInfoService({this.gpuSnapshot, this.defaultAdapter});

  final GpuSnapshot? gpuSnapshot;
  final GpuDefaultAdapter? defaultAdapter;

  @override
  Future<GpuSnapshot?> snapshot() async => gpuSnapshot;

  @override
  Future<GpuDefaultAdapter?> resolveDefault({bool refresh = false}) async =>
      defaultAdapter;
}

const _rtxLuid = 111;
const _intelLuid = 222;

GpuSnapshot _snapshot({int? preference = 2}) => GpuSnapshot(
  adapters: <GpuAdapter>[
    const GpuAdapter(
      name: 'NVIDIA GeForce RTX 3050 6GB Laptop GPU',
      vendorId: 0x10DE,
      deviceId: 0x25A2,
      luid: _rtxLuid,
      dedicatedVideoMemory: 6 * 1024 * 1024 * 1024,
      kind: GpuAdapterKind.discrete,
      localMemory: GpuMemoryInfo(
        usage: 1536 * 1024 * 1024,
        budget: 6 * 1024 * 1024 * 1024,
      ),
      nonLocalMemory: GpuMemoryInfo(
        usage: 100 * 1024 * 1024,
        budget: 8 * 1024 * 1024 * 1024,
      ),
    ),
    const GpuAdapter(
      name: 'Intel(R) UHD Graphics',
      vendorId: 0x8086,
      deviceId: 0x46A6,
      luid: _intelLuid,
      dedicatedVideoMemory: 128 * 1024 * 1024,
      kind: GpuAdapterKind.integrated,
      displayAttached: true,
    ),
  ],
  displayAdapterLuid: _intelLuid,
  preference: preference,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('GpuSnapshot', () {
    test('parses adapters, clamps bytes, and round-trips', () {
      final snapshot = GpuSnapshot.fromJson(<String, Object?>{
        'adapters': <Object?>[
          <String, Object?>{
            'name': 'NVIDIA GeForce RTX 3050 6GB Laptop GPU',
            'vendorId': 0x10DE,
            'deviceId': 0x25A2,
            'luid': _rtxLuid,
            'dedicatedVideoMemory': 6 * 1024 * 1024 * 1024,
            'dedicatedSystemMemory': -1,
            'sharedSystemMemory': 8 * 1024 * 1024 * 1024,
            'flags': 0,
            'kind': 'discrete',
            'displayAttached': false,
            'outputCount': 0,
            'memory': <String, Object?>{
              'local': <String, Object?>{
                'usage': 1024,
                'budget': 4096,
                'reservation': -1,
                'availableForReservation': 2048,
              },
            },
          },
          <String, Object?>{
            'name': 'Intel(R) UHD Graphics',
            'luid': _intelLuid,
            'kind': 'integrated',
            'displayAttached': true,
          },
          'not an adapter',
        ],
        'displayAdapterLuid': _intelLuid,
        'preference': 2,
      });

      expect(snapshot.adapters, hasLength(2));
      expect(snapshot.adapters.first.kind, GpuAdapterKind.discrete);
      expect(snapshot.adapters.first.dedicatedSystemMemory, 0);
      expect(snapshot.adapters.first.localMemory?.reservation, 0);
      expect(snapshot.displayAdapter?.name, 'Intel(R) UHD Graphics');
      expect(snapshot.adapterForLuid(_rtxLuid)?.kind, GpuAdapterKind.discrete);
      expect(snapshot.adapterForLuid(999), isNull);
      expect(snapshot.preference, 2);

      final decoded = GpuSnapshot.fromJson(
        jsonDecode(jsonEncode(snapshot.toJson())),
      );
      expect(decoded, snapshot);
    });

    test('drops an invalid preference and unknown kinds', () {
      final snapshot = GpuSnapshot.fromJson(<String, Object?>{
        'adapters': <Object?>[
          <String, Object?>{'name': 'Mystery', 'kind': 'apu'},
        ],
        'preference': 7,
      });

      expect(snapshot.preference, isNull);
      expect(snapshot.adapters.single.kind, GpuAdapterKind.unknown);
      expect(snapshot.adapters.single.luid, isNull);
    });
  });

  group('GpuInfoService', () {
    const channel = MethodChannel('mpvson/gpu_test');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    late int defaultProbeCount;
    late int? lastPreference;

    setUp(() {
      defaultProbeCount = 0;
      lastPreference = null;
      messenger.setMockMethodCallHandler(channel, (call) async {
        switch (call.method) {
          case 'snapshot':
            return <String, Object?>{
              'adapters': <Object?>[
                <String, Object?>{
                  'name': 'NVIDIA GeForce RTX 3050 6GB Laptop GPU',
                  'luid': _rtxLuid,
                  'kind': 'discrete',
                  'displayAttached': false,
                  'memory': <String, Object?>{
                    'local': <String, Object?>{'usage': 1024, 'budget': 4096},
                    'nonLocal': <String, Object?>{'usage': 512, 'budget': 8192},
                  },
                },
              ],
              'displayAdapterLuid': _intelLuid,
              'preference': 2,
            };
          case 'resolveDefault':
            defaultProbeCount++;
            return <String, Object?>{
              'luid': _rtxLuid,
              'name': 'NVIDIA GeForce RTX 3050 6GB Laptop GPU',
              'vendorId': 0x10DE,
              'deviceId': 0x25A2,
            };
          case 'readPreference':
            return 2;
          case 'setPreference':
            lastPreference = call.arguments as int;
            return true;
          case 'clearPreference':
            return true;
          default:
            return null;
        }
      });
    });

    tearDown(() {
      messenger.setMockMethodCallHandler(channel, null);
    });

    test('reads a snapshot and caches the default adapter probe', () async {
      final service = GpuInfoService(channel: channel);

      final snapshot = await service.snapshot();
      expect(snapshot?.adapters.single.localMemory?.usage, 1024);
      expect(snapshot?.displayAdapterLuid, _intelLuid);

      final first = await service.resolveDefault();
      final second = await service.resolveDefault();
      expect(first?.name, 'NVIDIA GeForce RTX 3050 6GB Laptop GPU');
      expect(second, first);
      expect(defaultProbeCount, 1);

      await service.resolveDefault(refresh: true);
      expect(defaultProbeCount, 2);
    });

    test('reads and writes the preference level', () async {
      final service = GpuInfoService(channel: channel);

      expect(await service.readPreference(), 2);
      expect(await service.setPreference(1), isTrue);
      expect(lastPreference, 1);
      expect(await service.setPreference(4), isFalse);
      expect(lastPreference, 1);
      expect(await service.clearPreference(), isTrue);
    });

    test('writes a snapshot file beside diagnostics', () async {
      final directory = await Directory.systemTemp.createTemp(
        'mpvson_gpu_test_',
      );
      addTearDown(() => directory.delete(recursive: true));

      final file = await GpuInfoService(
        channel: channel,
      ).writeSnapshot(directory: directory);
      expect(file, isNotNull);
      expect(await file!.exists(), isTrue);

      final Object? decoded = jsonDecode(await file.readAsString());
      expect(decoded, isA<Map<String, Object?>>());
      final payload = decoded! as Map<String, Object?>;
      expect(payload['preference'], 2);
      final defaultAdapter = payload['defaultAdapter'];
      expect(defaultAdapter, isA<Map<String, Object?>>());
      expect(
        (defaultAdapter! as Map<String, Object?>)['name'],
        'NVIDIA GeForce RTX 3050 6GB Laptop GPU',
      );
    });
  });

  group('PlaybackStatistics.gpuRows', () {
    test('formats the active adapter type and memory segments', () async {
      final rows = await PlaybackStatistics.gpuRows(
        _FakeGpuInfoService(
          gpuSnapshot: _snapshot(),
          defaultAdapter: const GpuDefaultAdapter(
            luid: _rtxLuid,
            name: 'NVIDIA GeForce RTX 3050 6GB Laptop GPU',
          ),
        ),
      );

      expect(rows['Active GPU'], 'NVIDIA GeForce RTX 3050 6GB Laptop GPU');
      expect(rows['GPU type'], 'Discrete');
      expect(rows['Dedicated memory (used / budget)'], '1.5 GB / 6.0 GB');
      expect(rows['Shared memory (used / budget)'], '100 MB / 8.0 GB');
    });

    test('reports unavailable rows when the default probe fails', () async {
      final rows = await PlaybackStatistics.gpuRows(_FakeGpuInfoService());

      for (final label in PlaybackStatistics.gpuProperties) {
        expect(rows[label], 'Unavailable');
      }
    });
  });

  group('PlaybackStatistics.read', () {
    test('keeps mpv rows and fills every GPU row', () async {
      final statistics = await PlaybackStatistics.read(
        (name) async => switch (name) {
          'hwdec-current' => 'd3d11va',
          'frame-drop-count' => '4',
          _ => '1',
        },
        readGpuRows: () async => <String, String>{
          'Active GPU': 'RTX 3050',
          'GPU type': 'Discrete',
        },
      );

      expect(statistics.values['Active decoder'], 'd3d11va');
      expect(statistics.values['Frames dropped by output'], '4');
      expect(statistics.values['Active GPU'], 'RTX 3050');
      expect(statistics.values['GPU type'], 'Discrete');
      expect(
        statistics.values['Dedicated memory (used / budget)'],
        'Unavailable',
      );
    });

    test('falls back to unavailable GPU rows when the reader throws', () async {
      final statistics = await PlaybackStatistics.read(
        (name) async => '',
        readGpuRows: () async => throw StateError('GPU probe failed'),
      );

      for (final label in PlaybackStatistics.gpuProperties) {
        expect(statistics.values[label], 'Unavailable');
      }
    });
  });

  group('PlaybackInfoDialog', () {
    testWidgets('refreshes samples once per second while open', (tester) async {
      var reads = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(
            body: PlaybackInfoDialog(
              readStatistics: () async {
                reads++;
                return PlaybackStatistics(<String, String>{
                  'Active GPU': 'GPU $reads',
                  'GPU type': 'Discrete',
                  'Dedicated memory (used / budget)': '1.0 GB / 6.0 GB',
                  'Shared memory (used / budget)': '0 MB / 8.0 GB',
                });
              },
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('Active GPU'), findsOneWidget);
      expect(find.text('GPU 1'), findsOneWidget);

      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(find.text('GPU 2'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
    });
  });
}
