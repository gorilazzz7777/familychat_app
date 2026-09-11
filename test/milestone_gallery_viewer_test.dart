import 'package:familychat_app/features/members/presentation/scrapbook/utils/milestone_gallery_viewer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('gallery viewer uses FamilyChat twin ids, not diary attachment ids', () {
    final photos = [
      {
        'id': 110,
        'url': 'https://cdn.example/smile-a.jpg',
        'file_url': 'https://cdn.example/smile-a.jpg',
        'attachment_id': 989,
        'thread_id': 7,
        'fc_attachment_id': 1902,
        'fc_thread_id': 1,
        'filename': 'IMG_4718.jpg',
      },
      {
        'id': 111,
        'url': 'https://cdn.example/smile-b.jpg',
        'file_url': 'https://cdn.example/smile-b.jpg',
        'attachment_id': 984,
        'thread_id': 7,
        'fc_attachment_id': 1897,
        'fc_thread_id': 1,
        'filename': 'IMG_4723.jpg',
      },
    ];

    final mapped = milestonePhotosForGalleryViewer(photos);
    expect(mapped, hasLength(2));
    expect(mapped.first['id'], 1902);
    expect(mapped.first['attachment_id'], 1902);
    expect(mapped.first['thread_id'], 1);
    expect(mapped.first['url'], 'https://cdn.example/smile-a.jpg');
    expect(mapped.last['id'], 1897);
  });

  test('mixed diary/fc payload does not open a partial FamilyChat gallery', () {
    final mapped = milestonePhotosForGalleryViewer([
      {
        'id': 110,
        'url': 'https://cdn.example/smile-a.jpg',
        'attachment_id': 989,
        'thread_id': 7,
        'fc_attachment_id': 1902,
        'fc_thread_id': 1,
      },
      {
        'id': 111,
        'url': 'https://cdn.example/smile-b.jpg',
        'attachment_id': 984,
        'thread_id': 7,
      },
    ]);
    expect(mapped, isEmpty);
  });

  test('url viewer strips diary ids so sqlite cannot overlay another file', () {
    final stripped = milestonePhotoForUrlViewer({
      'id': 110,
      'attachment_id': 989,
      'thread_id': 7,
      'filename': 'IMG_4718.jpg',
      'url': 'https://cdn.example/smile-a.jpg',
    });
    expect(stripped.containsKey('id'), isFalse);
    expect(stripped.containsKey('attachment_id'), isFalse);
    expect(stripped.containsKey('thread_id'), isFalse);
    expect(stripped.containsKey('filename'), isFalse);
    expect(stripped['url'], 'https://cdn.example/smile-a.jpg');
  });
}
