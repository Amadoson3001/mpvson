import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/utils/cli_arguments.dart';

void main() {
  group('parseCliArguments', () {
    test('recognizes --enqueue and -e flags', () {
      final longFlag = parseCliArguments(
        const ['--enqueue', 'https://example.com/a.mp4'],
        isWindows: true,
        workingDirectory: r'C:\Media',
      );
      expect(longFlag.enqueue, isTrue);
      expect(longFlag.sources, equals(const ['https://example.com/a.mp4']));

      final shortFlag = parseCliArguments(
        const ['-e', 'clip.mp4'],
        isWindows: true,
        workingDirectory: r'C:\Media',
      );
      expect(shortFlag.enqueue, isTrue);
      expect(shortFlag.sources, equals(const [r'C:\Media\clip.mp4']));
    });

    test('treats arguments after -- as literal media sources', () {
      final parsed = parseCliArguments(
        const ['--enqueue', '--', '-odd-name.mp4', '--not-a-flag.mkv'],
        isWindows: false,
        workingDirectory: '/home/user/videos',
      );
      expect(parsed.enqueue, isTrue);
      expect(
        parsed.sources,
        equals(const [
          '/home/user/videos/-odd-name.mp4',
          '/home/user/videos/--not-a-flag.mkv',
        ]),
      );
    });

    test('filters --engine-recovery and unknown flags before --', () {
      final parsed = parseCliArguments(
        const [
          '--engine-recovery=2',
          '--unknown-flag',
          '-x',
          '/?',
          'video.mp4',
        ],
        isWindows: true,
        workingDirectory: r'E:\clips',
      );
      expect(parsed.enqueue, isFalse);
      expect(parsed.sources, equals(const [r'E:\clips\video.mp4']));
    });

    test(
      'preserves HTTP(S) and file URIs verbatim and normalizes local paths',
      () {
        const signedUrl =
            'https://cdn.example.com/Watch%2FVideo?token=AbCd123&q=a+b';
        const fileUri = 'file:///C:/Videos/sample.mp4';
        final parsed = parseCliArguments(
          ['  $signedUrl  ', fileUri, r'.\sub\..\movie.mkv'],
          isWindows: true,
          workingDirectory: r'D:\Movies',
        );
        expect(
          parsed.sources,
          equals(const [signedUrl, fileUri, r'D:\Movies\movie.mkv']),
        );
      },
    );
  });
}
