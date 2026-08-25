import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/features/app_update/data/github_release_parser.dart';

void main() {
  test('parses the fork release tag', () {
    final release = GithubReleaseParser.parse({
      'tag_name': 'v4.1.3',
      'prerelease': false,
      'published_at': '2026-08-25T00:00:00Z',
      'html_url': 'https://github.com/ferras777/hiddify-app/releases/tag/v4.1.3',
    });

    expect(release.version, '4.1.3');
    expect(release.buildNumber, '');
    expect(release.releaseTag, 'v4.1.3');
    expect(release.preRelease, isFalse);
  });
}
