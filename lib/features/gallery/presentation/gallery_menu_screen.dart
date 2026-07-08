import 'package:flutter/material.dart';

import '../../profile/presentation/profile_gallery_tab.dart';
import 'family_gallery_tab.dart';

class GalleryMenuScreen extends StatelessWidget {
  const GalleryMenuScreen({
    super.key,
    required this.currentUserId,
  });

  final int currentUserId;

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Галерея'),
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Мои'),
              Tab(text: 'Все'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            ProfileGalleryTab(
              userId: currentUserId,
              isOwnGallery: true,
            ),
            FamilyGalleryTab(
              currentUserId: currentUserId,
              allowCreateAlbum: false,
            ),
          ],
        ),
      ),
    );
  }
}
