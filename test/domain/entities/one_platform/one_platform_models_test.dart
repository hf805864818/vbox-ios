/// One 平台数据模型单测：构造 + `id` 展示标识 + 默认值。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/domain/entities/one_platform/one_platform.dart';

void main() {
  test('OneCategory：id 取 cateId，icon 可空', () {
    const OneCategory c =
        OneCategory(cateId: '1', name: '国产', sortOrder: 1);
    expect(c.id, '1');
    expect(c.name, '国产');
    expect(c.icon, isNull);
    expect(c.sortOrder, 1);
  });

  test('OneVideoItem：默认 tags 为空列表，id 取 articleId', () {
    const OneVideoItem v = OneVideoItem(
      articleId: 'a1',
      title: '标题',
      cover: '',
      duration: '12:00',
      views: 100,
      likes: 3,
      categoryId: '1',
    );
    expect(v.id, 'a1');
    expect(v.tags, isEmpty);
    expect(v.rating, isNull);
    expect(v.categoryName, isNull);
  });

  test('OnePlaySource：id 取线路名', () {
    const OnePlaySource s =
        OnePlaySource(name: '高清', url: 'https://x/a.m3u8');
    expect(s.id, '高清');
    expect(s.url, 'https://x/a.m3u8');
  });

  test('OneVideoDetail：默认简介空串、playUrls 空列表', () {
    const OneVideoDetail d = OneVideoDetail(
      articleId: 'a1',
      title: 't',
      cover: '',
      duration: '',
      views: 0,
      likes: 0,
    );
    expect(d.description, '');
    expect(d.playUrls, isEmpty);
    expect(d.playUrl, isNull);
  });

  test('OneAlbum：默认章数 0、id 取 albumId', () {
    const OneAlbum a = OneAlbum(albumId: 'al1', title: '专辑', cover: '');
    expect(a.id, 'al1');
    expect(a.itemCount, 0);
    expect(a.description, '');
    expect(a.rating, isNull);
  });

  test('OneChapter：默认未付费/未读、id 取 chapterId', () {
    const OneChapter c =
        OneChapter(chapterId: 'ch1', title: '第1章', sortOrder: 0);
    expect(c.id, 'ch1');
    expect(c.isPaid, isFalse);
    expect(c.hasRead, isFalse);
  });
}