import 'package:flutter/material.dart';

import '../../../core/widgets/family_tab_bar.dart';
import '../../../core/widgets/family_app_bar.dart';
import '../../../app/app_actions_scope.dart';

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
        appBar: FamilyAppBar.build(
          title: 'Галерея',
          automaticallyImplyLeading: false,
          profileName: AppActions.displayName,
          profileAvatarUrl: AppActions.avatarUrl,
          onProfileTap: () => AppActions.openProfile(context),
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
