import 'package:background_downloader/src/models.dart';
import 'package:background_downloader/src/task.dart';
import 'package:background_downloader/src/utils.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('getContentLength', () {
    test('uses content-length case insensitively before task headers', () {
      final task = DownloadTask(
        url: 'https://example.com/file',
        headers: {'Range': 'bytes=0-20', 'Known-Content-Length': '99'},
      );

      expect(getContentLength({'cOnTeNt-LeNgTh': '42'}, task), 42);
    });

    test('uses bounded range and ignores open-ended range', () {
      final bounded = DownloadTask(
        url: 'https://example.com/file',
        headers: {'range': 'bytes=10-20'},
      );
      final openEnded = DownloadTask(
        url: 'https://example.com/file',
        headers: {'range': 'bytes=10-', 'known-content-length': '123'},
      );

      expect(getContentLength({}, bounded), 11);
      expect(getContentLength({}, openEnded), 123);
    });
  });

  group('taskWithSuggestedFilename', () {
    test('parses plain filename without trailing parameters', () async {
      final task = await taskWithSuggestedFilename(
        _task(),
        {'Content-Disposition': 'attachment; filename=plain.txt; size=123'},
        false,
      );

      expect(task.filename, 'plain.txt');
    });

    test('prefers encoded filename and preserves plus signs', () async {
      final task = await taskWithSuggestedFilename(
        _task(),
        {
          'content-disposition':
              'attachment; filename="fallback.txt"; filename*=UTF-8\'\'caf%C3%A9+a.txt',
        },
        false,
      );

      expect(task.filename, 'café+a.txt');
    });

    test('falls back to URL path segment', () async {
      final task = await taskWithSuggestedFilename(_task(), {}, false);

      expect(task.filename, 'fallback.bin');
    });
  });
}

DownloadTask _task() => DownloadTask(
      url: 'https://example.com/download/fallback.bin',
      filename: DownloadTask.suggestedFilename,
      updates: Updates.none,
    );
