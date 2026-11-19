import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/data/services/process_runner.dart';
import 'package:mpvson/data/services/yt_dlp_resolver.dart';
import 'package:mpvson/domain/models/resolved_stream.dart';

void main() {
  group('ResolvedStream & StreamRendition model', () {
    test('StreamRendition properties and equality', () {
      const rendition1 = StreamRendition(
        id: '137',
        url: 'https://cdn.example.com/1080p.mp4',
        audioUrl: 'https://cdn.example.com/audio.m4a',
        width: 1920,
        height: 1080,
        bitrate: 4000,
        frameRate: 60.0,
        videoCodec: 'avc1',
        audioCodec: 'mp4a',
        isMuxed: false,
      );

      const rendition2 = StreamRendition(
        id: '137',
        url: 'https://cdn.example.com/1080p.mp4',
        audioUrl: 'https://cdn.example.com/audio.m4a',
        width: 1920,
        height: 1080,
        bitrate: 4000,
        frameRate: 60.0,
        videoCodec: 'avc1',
        audioCodec: 'mp4a',
        isMuxed: false,
      );

      expect(rendition1, equals(rendition2));
      expect(rendition1.hashCode, equals(rendition2.hashCode));
      expect(rendition1.hasVideo, isTrue);
      expect(rendition1.hasAudio, isTrue);
      expect(rendition1.resolution, equals('1080p'));
      expect(rendition1.qualityLabel, equals('1080p (60fps)'));

      final modified = rendition1.copyWith(height: 720, fps: 30.0);
      expect(modified.height, equals(720));
      expect(modified.qualityLabel, equals('720p'));
      expect(modified, isNot(equals(rendition1)));
    });

    test('ResolvedStream copyWith, equality and expiry helpers', () {
      final now = DateTime.utc(2026, 11, 19, 12, 0, 0);
      final expiresAt = now.add(const Duration(minutes: 10));

      final stream1 = ResolvedStream(
        originalUrl: 'https://youtube.com/watch?v=abc',
        streamUrl: 'https://cdn.example.com/stream.mp4',
        audioUrl: 'https://cdn.example.com/audio.m4a',
        title: 'Sample Video',
        httpHeaders: const {'User-Agent': 'Test'},
        renditions: const [],
        isExpiring: true,
        expiresAt: expiresAt,
        formatId: '137',
        extractor: 'youtube',
        duration: const Duration(seconds: 120),
      );

      final stream2 = stream1.copyWith();
      expect(stream1, equals(stream2));
      expect(stream1.hashCode, equals(stream2.hashCode));
      expect(stream1.hasSeparateAudio, isTrue);

      // Expiry checks
      expect(stream1.isExpired(now: now), isFalse);
      expect(
        stream1.isNearExpiry(now: now, threshold: const Duration(minutes: 15)),
        isTrue,
      );
      expect(
        stream1.isNearExpiry(now: now, threshold: const Duration(minutes: 5)),
        isFalse,
      );
      expect(
        stream1.isExpired(now: now.add(const Duration(minutes: 11))),
        isTrue,
      );

      final clearedAudio = stream1.copyWith(clearAudioUrl: true);
      expect(clearedAudio.audioUrl, isNull);
      expect(clearedAudio.hasSeparateAudio, isFalse);
    });
  });

  group('YtDlpResolver URL capability checks', () {
    late YtDlpResolver resolver;

    setUp(() {
      resolver = YtDlpResolver(runner: _FakeProcessRunner());
    });

    test('canResolve identifies supported video page hosts', () {
      expect(
        resolver.canResolve('https://www.youtube.com/watch?v=dQw4w9WgXcQ'),
        isTrue,
      );
      expect(resolver.canResolve('https://youtu.be/dQw4w9WgXcQ'), isTrue);
      expect(resolver.canResolve('https://vimeo.com/76979871'), isTrue);
      expect(
        resolver.canResolve('https://www.twitch.tv/videos/1234567'),
        isTrue,
      );
      expect(
        resolver.canResolve('https://soundcloud.com/artist/track-name'),
        isTrue,
      );
      expect(
        resolver.canResolve('https://www.tiktok.com/@user/video/12345'),
        isTrue,
      );
    });

    test(
      'canResolve identifies generic web pages and rejects direct media files',
      () {
        // Generic web page without media extension
        expect(
          resolver.canResolve('https://example.com/watch/video-player'),
          isTrue,
        );

        // Direct media files
        expect(resolver.canResolve('https://example.com/video.mp4'), isFalse);
        expect(resolver.canResolve('https://example.com/movie.mkv'), isFalse);
        expect(resolver.canResolve('https://example.com/stream.m3u8'), isFalse);
        expect(
          resolver.canResolve('https://example.com/manifest.mpd'),
          isFalse,
        );
        expect(resolver.canResolve('https://example.com/audio.mp3'), isFalse);

        // Non-network URLs
        expect(resolver.canResolve('file:///C:/videos/test.mp4'), isFalse);
        expect(resolver.canResolve('ftp://server/media.mp4'), isFalse);
        expect(resolver.canResolve(''), isFalse);
        expect(resolver.canResolve('   '), isFalse);
      },
    );
  });

  group('YtDlpResolver arguments & process execution', () {
    test(
      'passes exact arguments: --ignore-config, --no-playlist, --no-download, --dump-single-json, --, url',
      () async {
        final runner = _FakeProcessRunner(stdoutContent: _sampleMuxedJson);
        final resolver = YtDlpResolver(runner: runner);

        await resolver.resolve('https://www.youtube.com/watch?v=test');

        expect(runner.startCalls.length, equals(1));
        final call = runner.startCalls.first;
        expect(call.runInShell, isFalse);
        expect(
          call.arguments,
          equals([
            '--ignore-config',
            '--no-playlist',
            '--no-download',
            '--dump-single-json',
            '--',
            'https://www.youtube.com/watch?v=test',
          ]),
        );
      },
    );
  });

  group('YtDlpResolver format selection & JSON parsing', () {
    test('prefers viable muxed formats when available', () async {
      final runner = _FakeProcessRunner(stdoutContent: _sampleMuxedJson);
      final resolver = YtDlpResolver(runner: runner);

      final result = await resolver.resolve('https://youtube.com/watch?v=test');

      expect(result.title, equals('Sample Muxed Video'));
      expect(result.extractor, equals('youtube'));
      expect(result.duration, equals(const Duration(seconds: 180)));
      // Should choose format 22 (720p muxed) over video-only 137 (1080p)
      expect(result.formatId, equals('22'));
      expect(result.streamUrl, equals('https://cdn.example.com/720p.mp4'));
      expect(result.audioUrl, isNull);

      // Renditions list should contain all video formats
      expect(result.renditions.length, equals(3));
      // 1080p rendition (video-only) is paired with best audio (format 140)
      final r1080 = result.renditions.firstWhere((r) => r.formatId == '137');
      expect(r1080.height, equals(1080));
      expect(r1080.isMuxed, isFalse);
      expect(r1080.audioUrl, equals('https://cdn.example.com/140.m4a'));

      // 720p rendition (muxed)
      final r720 = result.renditions.firstWhere((r) => r.formatId == '22');
      expect(r720.height, equals(720));
      expect(r720.isMuxed, isTrue);
      expect(r720.audioUrl, isNull);
    });

    test(
      'pairs best video with compatible audio format when only separate formats exist',
      () async {
        final runner = _FakeProcessRunner(stdoutContent: _sampleSplitJson);
        final resolver = YtDlpResolver(runner: runner);

        final result = await resolver.resolve(
          'https://youtube.com/watch?v=split',
        );

        expect(result.title, equals('Split Audio Video'));
        // Selected stream should be highest video format paired with best audio format
        expect(result.formatId, equals('137'));
        expect(
          result.streamUrl,
          equals('https://cdn.example.com/video_1080p.mp4'),
        );
        expect(
          result.audioUrl,
          equals('https://cdn.example.com/audio_140.m4a'),
        );
        expect(result.hasSeparateAudio, isTrue);

        // Both video renditions are paired with the audio stream
        for (final r in result.renditions) {
          expect(r.isMuxed, isFalse);
          expect(r.audioUrl, equals('https://cdn.example.com/audio_140.m4a'));
        }
      },
    );

    test('handles audio-only extractors like soundcloud', () async {
      final runner = _FakeProcessRunner(stdoutContent: _sampleAudioOnlyJson);
      final resolver = YtDlpResolver(runner: runner);

      final result = await resolver.resolve(
        'https://soundcloud.com/artist/song',
      );

      expect(result.formatId, equals('audio_high'));
      expect(result.streamUrl, equals('https://cdn.example.com/song_high.mp3'));
      expect(result.audioUrl, isNull);
      expect(result.renditions.length, equals(2));
    });

    test(
      'strips unsafe headers and credentials while retaining safe headers',
      () async {
        final runner = _FakeProcessRunner(stdoutContent: _sampleHeadersJson);
        final resolver = YtDlpResolver(runner: runner);

        final result = await resolver.resolve('https://example.com/video');

        expect(result.httpHeaders, isNotNull);
        final headers = result.httpHeaders!;

        // Safe headers retained
        expect(headers['User-Agent'], equals('TestBrowser/1.0'));
        expect(headers['Referer'], equals('https://example.com'));
        expect(headers['Accept'], equals('*/*'));

        // Sensitive and hop-by-hop headers stripped
        expect(headers.containsKey('Authorization'), isFalse);
        expect(headers.containsKey('Cookie'), isFalse);
        expect(headers.containsKey('Set-Cookie'), isFalse);
        expect(headers.containsKey('Connection'), isFalse);
        expect(headers.containsKey('Keep-Alive'), isFalse);
        expect(headers.containsKey('Transfer-Encoding'), isFalse);

        // Header with CRLF injection stripped
        expect(headers.containsKey('X-Injected'), isFalse);
      },
    );
  });

  group('YtDlpResolver expiring token detection & refresh', () {
    test(
      'extracts expiration token from URL parameters and sets isExpiring',
      () async {
        // 1732021200 = 2024-11-19T13:00:00Z
        final runner = _FakeProcessRunner(stdoutContent: _sampleExpiringJson);
        final resolver = YtDlpResolver(runner: runner);

        final result = await resolver.resolve(
          'https://youtube.com/watch?v=expiring',
        );

        expect(result.isExpiring, isTrue);
        expect(result.expiresAt, isNotNull);
        expect(
          result.expiresAt,
          equals(
            DateTime.fromMillisecondsSinceEpoch(1732021200 * 1000, isUtc: true),
          ),
        );
      },
    );

    test('refresh re-resolves stream and restores chosen format', () async {
      var callCount = 0;
      final runner = _FakeProcessRunner(
        onStart: (exe, args) {
          callCount++;
          if (callCount == 1) {
            return _FakeProcess(stdoutContent: _sampleMuxedJson);
          } else {
            return _FakeProcess(
              stdoutContent: _sampleMuxedJson.replaceAll(
                'https://cdn.example.com/720p.mp4',
                'https://cdn.example.com/720p_refreshed.mp4',
              ),
            );
          }
        },
      );
      final resolver = YtDlpResolver(runner: runner);

      final initial = await resolver.resolve(
        'https://youtube.com/watch?v=test',
      );
      expect(initial.streamUrl, equals('https://cdn.example.com/720p.mp4'));

      final refreshed = await resolver.refresh(initial);
      expect(
        refreshed.streamUrl,
        equals('https://cdn.example.com/720p_refreshed.mp4'),
      );
      expect(refreshed.formatId, equals(initial.formatId));
    });
  });

  group('YtDlpResolver cancellation and timeout', () {
    test('cancels immediately if token is already cancelled', () async {
      final runner = _FakeProcessRunner(stdoutContent: _sampleMuxedJson);
      final resolver = YtDlpResolver(runner: runner);

      final token = CancellationToken()..cancel();

      expect(
        () => resolver.resolve(
          'https://youtube.com/watch?v=test',
          cancelToken: token,
        ),
        throwsA(isA<YtDlpCancelledException>()),
      );
      expect(runner.startCalls, isEmpty);
    });

    test('cancels in-flight process and kills process cleanly', () async {
      late _FakeProcess fakeProcess;
      final runner = _FakeProcessRunner(
        onStart: (exe, args) {
          fakeProcess = _FakeProcess(
            stdoutContent: _sampleMuxedJson,
            exitDelay: const Duration(seconds: 10),
          );
          return fakeProcess;
        },
      );
      final resolver = YtDlpResolver(runner: runner);
      final token = CancellationToken();

      final resolveFuture = resolver.resolve(
        'https://youtube.com/watch?v=test',
        cancelToken: token,
      );

      // Allow process to start
      await Future<void>.delayed(const Duration(milliseconds: 20));
      token.cancel();

      await expectLater(resolveFuture, throwsA(isA<YtDlpCancelledException>()));
      expect(fakeProcess.wasKilled, isTrue);
    });

    test('times out and kills process if duration exceeded', () async {
      late _FakeProcess fakeProcess;
      final runner = _FakeProcessRunner(
        onStart: (exe, args) {
          fakeProcess = _FakeProcess(
            stdoutContent: _sampleMuxedJson,
            exitDelay: const Duration(seconds: 5),
          );
          return fakeProcess;
        },
      );
      final resolver = YtDlpResolver(runner: runner);

      await expectLater(
        resolver.resolve(
          'https://youtube.com/watch?v=test',
          timeout: const Duration(milliseconds: 50),
        ),
        throwsA(isA<TimeoutException>()),
      );
      expect(fakeProcess.wasKilled, isTrue);
    });
  });

  group('YtDlpResolver error classification & diagnostics', () {
    test('classifies unsupported url error', () async {
      final runner = _FakeProcessRunner(
        exitCode: 1,
        stderrContent: 'ERROR: Unsupported URL: https://unknown.site/page',
      );
      final resolver = YtDlpResolver(runner: runner);

      await expectLater(
        resolver.resolve('https://unknown.site/page'),
        throwsA(
          predicate<YtDlpResolutionException>(
            (e) => e.errorType == YtDlpErrorType.unsupportedUrl,
          ),
        ),
      );
    });

    test('classifies sign-in required error', () async {
      final runner = _FakeProcessRunner(
        exitCode: 1,
        stderrContent: 'ERROR: Sign in to confirm you’re not a bot',
      );
      final resolver = YtDlpResolver(runner: runner);

      await expectLater(
        resolver.resolve('https://youtube.com/watch?v=bot'),
        throwsA(
          predicate<YtDlpResolutionException>(
            (e) => e.errorType == YtDlpErrorType.loginRequired,
          ),
        ),
      );
    });

    test('classifies video unavailable error', () async {
      final runner = _FakeProcessRunner(
        exitCode: 1,
        stderrContent:
            'ERROR: [youtube] 1234: Video unavailable. This video has been removed.',
      );
      final resolver = YtDlpResolver(runner: runner);

      await expectLater(
        resolver.resolve('https://youtube.com/watch?v=1234'),
        throwsA(
          predicate<YtDlpResolutionException>(
            (e) => e.errorType == YtDlpErrorType.videoUnavailable,
          ),
        ),
      );
    });

    test('classifies geo-restricted error', () async {
      final runner = _FakeProcessRunner(
        exitCode: 1,
        stderrContent: 'ERROR: This video is not available in your country',
      );
      final resolver = YtDlpResolver(runner: runner);

      await expectLater(
        resolver.resolve('https://youtube.com/watch?v=geo'),
        throwsA(
          predicate<YtDlpResolutionException>(
            (e) => e.errorType == YtDlpErrorType.geoRestricted,
          ),
        ),
      );
    });

    test('classifies rate-limited error', () async {
      final runner = _FakeProcessRunner(
        exitCode: 1,
        stderrContent: 'ERROR: HTTP Error 429: Too Many Requests',
      );
      final resolver = YtDlpResolver(runner: runner);

      await expectLater(
        resolver.resolve('https://youtube.com/watch?v=429'),
        throwsA(
          predicate<YtDlpResolutionException>(
            (e) => e.errorType == YtDlpErrorType.rateLimited,
          ),
        ),
      );
    });

    test('rejects playlist and collection outputs', () async {
      const playlistJson = '''
      {
        "_type": "playlist",
        "title": "Music Playlist",
        "entries": [{"id": "1"}, {"id": "2"}]
      }
      ''';
      final runner = _FakeProcessRunner(stdoutContent: playlistJson);
      final resolver = YtDlpResolver(runner: runner);

      await expectLater(
        resolver.resolve('https://youtube.com/playlist?list=123'),
        throwsA(
          predicate<YtDlpResolutionException>(
            (e) => e.errorType == YtDlpErrorType.unsupportedUrl,
          ),
        ),
      );
    });

    test('throws YtDlpNotFoundException when executable is missing', () async {
      final runner = _FakeProcessRunner(
        onStart: (exe, args) => throw const ProcessException(
          'yt-dlp',
          [],
          'The system cannot find the file specified.',
          2,
        ),
      );
      final resolver = YtDlpResolver(runner: runner);

      await expectLater(
        resolver.resolve('https://youtube.com/watch?v=missing'),
        throwsA(isA<YtDlpNotFoundException>()),
      );
    });

    test(
      'checkAvailability reports available, outdated, missing, and failed status',
      () async {
        // Available
        var runner = _FakeProcessRunner(runStdout: '2025.01.15\n');
        var resolver = YtDlpResolver(runner: runner);
        var status = await resolver.checkAvailability();
        expect(status.availability, equals(YtDlpAvailability.available));
        expect(status.version, equals('2025.01.15'));

        // Outdated (before 2023)
        runner = _FakeProcessRunner(runStdout: '2021.12.01\n');
        resolver = YtDlpResolver(runner: runner);
        status = await resolver.checkAvailability();
        expect(status.availability, equals(YtDlpAvailability.outdated));

        // Missing
        runner = _FakeProcessRunner(
          onRun: (exe, args) => throw const ProcessException(
            'yt-dlp',
            ['--version'],
            'Not found',
            2,
          ),
        );
        resolver = YtDlpResolver(runner: runner);
        status = await resolver.checkAvailability();
        expect(status.availability, equals(YtDlpAvailability.missing));

        // Failed (non-zero exit)
        runner = _FakeProcessRunner(
          runExitCode: 1,
          runStderr: 'Permission denied',
        );
        resolver = YtDlpResolver(runner: runner);
        status = await resolver.checkAvailability();
        expect(status.availability, equals(YtDlpAvailability.failed));
      },
    );
  });
}

// ---------------------------------------------------------------------------
// Test Doubles and Fixtures
// ---------------------------------------------------------------------------

class _StartCall {
  final String executable;
  final List<String> arguments;
  final bool runInShell;

  _StartCall(this.executable, this.arguments, this.runInShell);
}

class _FakeProcessRunner extends ProcessRunner {
  final String stdoutContent;
  final String stderrContent;
  final int exitCode;
  final String runStdout;
  final String runStderr;
  final int runExitCode;
  final _FakeProcess Function(String exe, List<String> args)? onStart;
  final Future<ProcessExecutionResult> Function(String exe, List<String> args)?
  onRun;

  final List<_StartCall> startCalls = [];

  _FakeProcessRunner({
    this.stdoutContent = '',
    this.stderrContent = '',
    this.exitCode = 0,
    this.runStdout = '',
    this.runStderr = '',
    this.runExitCode = 0,
    this.onStart,
    this.onRun,
  });

  @override
  Future<ProcessExecutionResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
    bool runInShell = false,
    Encoding? stdoutEncoding = systemEncoding,
    Encoding? stderrEncoding = systemEncoding,
    Duration? timeout,
  }) async {
    if (onRun != null) {
      return onRun!(executable, arguments);
    }
    return ProcessExecutionResult(
      exitCode: runExitCode,
      stdout: runStdout,
      stderr: runStderr,
      elapsed: const Duration(milliseconds: 10),
    );
  }

  @override
  Future<Process> start(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
    bool runInShell = false,
    ProcessStartMode mode = ProcessStartMode.normal,
  }) async {
    startCalls.add(_StartCall(executable, arguments, runInShell));
    if (onStart != null) {
      return onStart!(executable, arguments);
    }
    return _FakeProcess(
      stdoutContent: stdoutContent,
      stderrContent: stderrContent,
      exitCode: exitCode,
    );
  }
}

class _FakeProcess implements Process {
  final String stdoutContent;
  final String stderrContent;
  final int exitCodeValue;
  final Duration? exitDelay;

  final Completer<int> _exitCompleter = Completer<int>();
  bool wasKilled = false;

  _FakeProcess({
    this.stdoutContent = '',
    this.stderrContent = '',
    int exitCode = 0,
    this.exitDelay,
  }) : exitCodeValue = exitCode {
    if (exitDelay != null) {
      Timer(exitDelay!, () {
        if (!_exitCompleter.isCompleted) {
          _exitCompleter.complete(exitCodeValue);
        }
      });
    } else {
      _exitCompleter.complete(exitCodeValue);
    }
  }

  @override
  Future<int> get exitCode => _exitCompleter.future;

  @override
  Stream<List<int>> get stdout =>
      Stream.value(utf8.encode(stdoutContent)).asBroadcastStream();

  @override
  Stream<List<int>> get stderr =>
      Stream.value(utf8.encode(stderrContent)).asBroadcastStream();

  @override
  IOSink get stdin => _DummyIOSink();

  @override
  int get pid => 99999;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    wasKilled = true;
    if (!_exitCompleter.isCompleted) {
      _exitCompleter.complete(-1);
    }
    return true;
  }
}

class _DummyIOSink implements IOSink {
  @override
  Encoding encoding = utf8;

  @override
  void add(List<int> data) {}

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<List<int>> stream) async {}

  @override
  Future<void> close() async {}

  @override
  Future<void> get done => Future<void>.value();

  @override
  Future<void> flush() async {}

  @override
  void write(Object? object) {}

  @override
  void writeAll(Iterable<dynamic> objects, [String separator = ""]) {}

  @override
  void writeCharCode(int charCode) {}

  @override
  void writeln([Object? object = ""]) {}
}

const String _sampleMuxedJson = '''
{
  "id": "test",
  "title": "Sample Muxed Video",
  "duration": 180,
  "extractor": "youtube",
  "http_headers": {
    "User-Agent": "TestBrowser/1.0"
  },
  "formats": [
    {
      "format_id": "18",
      "url": "https://cdn.example.com/360p.mp4",
      "vcodec": "avc1.42001E",
      "acodec": "mp4a.40.2",
      "height": 360,
      "width": 640,
      "tbr": 600,
      "ext": "mp4"
    },
    {
      "format_id": "22",
      "url": "https://cdn.example.com/720p.mp4",
      "vcodec": "avc1.64001F",
      "acodec": "mp4a.40.2",
      "height": 720,
      "width": 1280,
      "tbr": 1500,
      "ext": "mp4"
    },
    {
      "format_id": "137",
      "url": "https://cdn.example.com/1080p.mp4",
      "vcodec": "avc1.640028",
      "acodec": "none",
      "height": 1080,
      "width": 1920,
      "tbr": 4000,
      "ext": "mp4"
    },
    {
      "format_id": "140",
      "url": "https://cdn.example.com/140.m4a",
      "vcodec": "none",
      "acodec": "mp4a.40.2",
      "abr": 128,
      "tbr": 128,
      "ext": "m4a"
    }
  ]
}
''';

const String _sampleSplitJson = '''
{
  "id": "split",
  "title": "Split Audio Video",
  "duration": 300,
  "extractor": "youtube",
  "formats": [
    {
      "format_id": "136",
      "url": "https://cdn.example.com/video_720p.mp4",
      "vcodec": "avc1.4d401f",
      "acodec": "none",
      "height": 720,
      "width": 1280,
      "tbr": 1200,
      "ext": "mp4"
    },
    {
      "format_id": "137",
      "url": "https://cdn.example.com/video_1080p.mp4",
      "vcodec": "avc1.640028",
      "acodec": "none",
      "height": 1080,
      "width": 1920,
      "tbr": 3500,
      "ext": "mp4"
    },
    {
      "format_id": "140",
      "url": "https://cdn.example.com/audio_140.m4a",
      "vcodec": "none",
      "acodec": "mp4a.40.2",
      "abr": 128,
      "tbr": 128,
      "ext": "m4a"
    }
  ]
}
''';

const String _sampleAudioOnlyJson = '''
{
  "id": "song",
  "title": "Sample Song",
  "duration": 210,
  "extractor": "soundcloud",
  "formats": [
    {
      "format_id": "audio_low",
      "url": "https://cdn.example.com/song_low.mp3",
      "vcodec": "none",
      "acodec": "mp3",
      "abr": 128,
      "tbr": 128,
      "ext": "mp3"
    },
    {
      "format_id": "audio_high",
      "url": "https://cdn.example.com/song_high.mp3",
      "vcodec": "none",
      "acodec": "mp3",
      "abr": 320,
      "tbr": 320,
      "ext": "mp3"
    }
  ]
}
''';

const String _sampleHeadersJson = '''
{
  "id": "headers",
  "title": "Headers Test",
  "url": "https://cdn.example.com/direct.mp4",
  "http_headers": {
    "User-Agent": "TestBrowser/1.0",
    "Referer": "https://example.com",
    "Accept": "*/*",
    "Authorization": "Bearer secret_token",
    "Cookie": "session=secret_cookie",
    "Set-Cookie": "bad=1",
    "Connection": "keep-alive",
    "Keep-Alive": "timeout=5",
    "Transfer-Encoding": "chunked",
    "X-Injected\\r\\nHeader": "evil"
  }
}
''';

const String _sampleExpiringJson = '''
{
  "id": "expiring",
  "title": "Expiring Stream",
  "url": "https://rr1---sn-xxx.googlevideo.com/videoplayback?expire=1732021200&ei=123"
}
''';
