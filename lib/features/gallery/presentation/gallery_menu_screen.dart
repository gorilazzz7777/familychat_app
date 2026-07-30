import 'package:flutter/material.dart';

import '../../../core/widgets/family_tab_bar.dart';
import '../../../core/widgets/family_app_bar.dart';
import '../../../app/app_actions_scope.dart';

import '../../profile/presentation/profile_gallery_tab.dart';
import 'family_gallery_tab.dart';

class GalleryMenuScreen extends StatefulWidget {
  const GalleryMenuScreen({
    super.key,
    required this.currentUserId,
  });

  final int currentUserId;

  @override
  State<GalleryMenuScreen> createState() => _GalleryMenuScreenState();
}

class _GalleryMenuScreenState extends State<GalleryMenuScreen> {
  final _mineKey = GlobalKey<ProfileGalleryTabState>();
  final _familyKey = GlobalKey<FamilyGalleryTabState>();

  Future<void> _createAlbum() async {
    final created = await _mineKey.currentState?.createAlbum();
    if (created == true) {
      await _familyKey.currentState?.refresh(silent: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: FamilyAppBar.build(
          title: 'Галерея',
          automaticallyImplyLeading: false,
          profileName: AppActions.displayName,
          profileAvatarUrl: AppActions.avatarUrl,
          onProfileTap: () => AppActions.openProfile(context),
          actions: [
            IconButton(
              icon: const Icon(Icons.add),
              tooltip: 'Новый альбом',
              onPressed: _createAlbum,
            ),
          ],
          bottom: FamilyTabBar.build(
            tabs: const [
              Tab(text: 'Мои'),
              Tab(text: 'Все'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            ProfileGalleryTab(
              key: _mineKey,
              userId: widget.currentUserId,
              isOwnGallery: true,
            ),
            FamilyGalleryTab(
              key: _familyKey,
              currentUserId: widget.currentUserId,
              allowCreateAlbum: false,
            ),
          ],
        ),
      ),
    );
  }
}
