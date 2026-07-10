import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../../core/widgets/family_tab_bar.dart';
import '../../../core/widgets/family_app_bar.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/theme/theme_seed_controller.dart';
import 'theme_appearance_screen.dart';
import 'avatar_crop_screen.dart';
import 'birthday_format.dart';
import 'birthday_picker.dart';
import 'profile_gallery_tab.dart';
import '../../chat/presentation/widgets/chat_image_viewer.dart';
import 'widgets/chat_avatar.dart';

class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({
    super.key,
    required this.status,
    required this.onLogout,
    required this.onStatusChanged,
  });

  final Map<String, dynamic> status;
  final Future<void> Function() onLogout;
  final VoidCallback onStatusChanged;

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  final _firstName = TextEditingController();
  final _lastName = TextEditingController();
  String _gender = 'male';
  DateTime? _birthDate;
  bool _birthdayShowYear = true;
  String? _avatarUrl;
  bool _avatarBusy = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
    _applyStatus(widget.status);
  }

  @override
  void didUpdateWidget(covariant ProfileScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.status != widget.status) {
      _applyStatus(widget.status);
    }
  }

  @override
  void dispose() {
    _tabs.dispose();
    _firstName.dispose();
    _lastName.dispose();
    super.dispose();
  }

  void _applyStatus(Map<String, dynamic> status) {
    _firstName.text = status['first_name']?.toString() ?? '';
    _lastName.text = status['last_name']?.toString() ?? '';
    final g = status['gender']?.toString() ?? '';
    if (g == 'male' || g == 'female') _gender = g;
    _birthDate = parseBirthDate(status['birth_date']?.toString());
    _birthdayShowYear = status['birthday_show_year'] != false;
    final url = status['avatar_url']?.toString() ?? '';
    _avatarUrl = url.isEmpty ? null : url;
  }

  String get _displayName {
    final full = '${_firstName.text} ${_lastName.text}'.trim();
    if (full.isNotEmpty) return full;
    return widget.status['display_name']?.toString() ?? 'Профиль';
  }

  Future<void> _pickBirthDate() async {
    final picked = await showBirthDatePicker(
      context,
      initial: _birthDate,
      initialShowYear: _birthdayShowYear,
    );
    if (picked == null) return;
    setState(() {
      _birthDate = picked.date;
      _birthdayShowYear = picked.showYear;
    });
  }

  Future<void> _saveProfile() async {
    if (_birthDate == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Укажите день рождения')),
      );
      return;
    }
    setState(() => _saving = true);
    try {
      await ref.read(familychatRepositoryProvider).updateProfile(
            firstName: _firstName.text.trim(),
            lastName: _lastName.text.trim(),
            gender: _gender,
            birthDate: formatBirthDateForApi(_birthDate!),
            birthdayShowYear: _birthdayShowYear,
          );
      if (!mounted) return;
      widget.onStatusChanged();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Профиль сохранён')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Ошибка: $e')),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _showAvatarOptions() async {
    if (_avatarBusy) return;
    final hasPhoto = _avatarUrl != null && _avatarUrl!.isNotEmpty;
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (hasPhoto)
              ListTile(
                leading: const Icon(Icons.visibility_outlined),
                title: const Text('Просмотр'),
                onTap: () => Navigator.pop(ctx, 'view'),
              ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Выбрать из галереи'),
              onTap: () => Navigator.pop(ctx, 'gallery'),
            ),
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Сделать фото'),
              onTap: () => Navigator.pop(ctx, 'camera'),
            ),
            if (hasPhoto)
              ListTile(
                leading: Icon(Icons.delete_outline, color: Theme.of(ctx).colorScheme.error),
                title: Text(
                  'Удалить фото',
                  style: TextStyle(color: Theme.of(ctx).colorScheme.error),
                ),
                onTap: () => Navigator.pop(ctx, 'delete'),
              ),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case 'view':
        await _viewAvatar();
      case 'gallery':
        await _uploadAvatar(ImageSource.gallery);
      case 'camera':
        await _uploadAvatar(ImageSource.camera);
      case 'delete':
        await _deleteAvatar();
    }
  }

  Future<void> _viewAvatar() async {
    final url = _avatarUrl?.trim();
    if (url == null || url.isEmpty || !mounted) return;
    await ChatImageViewer.open(
      context,
      imageUrl: url,
      filename: 'avatar.jpg',
    );
  }

  Future<void> _uploadAvatar(ImageSource source) async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(
      source: source,
      maxWidth: 2048,
      maxHeight: 2048,
      imageQuality: 92,
    );
    if (picked == null || !mounted) return;

    final rawBytes = await picked.readAsBytes();
    if (!mounted) return;

    final croppedBytes = await AvatarCropScreen.open(
      context,
      imageBytes: rawBytes,
    );
    if (croppedBytes == null || !mounted) return;

    setState(() => _avatarBusy = true);
    try {
      final data = await ref
          .read(familychatRepositoryProvider)
          .uploadProfileAvatarBytes(croppedBytes);
      if (!mounted) return;
      final url = data['avatar_url']?.toString() ?? '';
      setState(() => _avatarUrl = url.isEmpty ? null : url);
      widget.onStatusChanged();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Фото сохранено')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Ошибка: $e')),
      );
    } finally {
      if (mounted) setState(() => _avatarBusy = false);
    }
  }

  Future<void> _deleteAvatar() async {
    setState(() => _avatarBusy = true);
    try {
      await ref.read(familychatRepositoryProvider).deleteProfileAvatar();
      if (!mounted) return;
      setState(() => _avatarUrl = null);
      widget.onStatusChanged();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Фото удалено')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Ошибка: $e')),
      );
    } finally {
      if (mounted) setState(() => _avatarBusy = false);
    }
  }

  Future<void> _confirmLogout() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Выйти'),
        content: const Text('Вы уверены, что хотите выйти из аккаунта?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Выйти'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await widget.onLogout();
  }

  Future<void> _confirmDeleteAccount() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Удалить профиль'),
        content: const Text(
          'Это действие необратимо. Будут удалены ваш аккаунт и все данные '
          'Family Chat, включая сообщения и связи в семье.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    try {
      await ref.read(authRepositoryProvider).deleteAccount(confirmDeletion: true);
      await widget.onLogout();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось удалить аккаунт: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final userId = widget.status['user_id'];
    return Scaffold(
      appBar: FamilyAppBar.build(
        title: 'Профиль',
        bottom: FamilyTabBar.build(
          controller: _tabs,
          tabs: const [
            Tab(text: 'Основное'),
            Tab(text: 'Галерея'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [
          _buildMainTab(context),
          if (userId is int)
            ProfileGalleryTab(userId: userId, isOwnGallery: true)
          else
            const Center(child: Text('Галерея недоступна')),
        ],
      ),
    );
  }

  Widget _buildMainTab(BuildContext context) {
    final theme = Theme.of(context);
    final birthLabel = _birthDate == null
        ? 'Не указан'
        : formatBirthDateDisplay(_birthDate!, showYear: true);

    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
      children: [
        Center(
          child: GestureDetector(
            onTap: _avatarBusy ? null : _showAvatarOptions,
            child: SizedBox(
              width: 112,
              height: 112,
              child: Stack(
                children: [
                  ChatAvatar(
                    name: _displayName,
                    avatarUrl: _avatarUrl,
                    radius: 56,
                  ),
                  if (_avatarBusy)
                    const Positioned.fill(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.black38,
                        ),
                        child: Center(
                          child: SizedBox(
                            width: 28,
                            height: 28,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 24),
        TextField(
          controller: _firstName,
          decoration: const InputDecoration(
            labelText: 'Имя',
            border: OutlineInputBorder(),
          ),
          textCapitalization: TextCapitalization.words,
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _lastName,
          decoration: const InputDecoration(
            labelText: 'Фамилия',
            border: OutlineInputBorder(),
          ),
          textCapitalization: TextCapitalization.words,
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          initialValue: _gender,
          decoration: const InputDecoration(
            labelText: 'Пол',
            border: OutlineInputBorder(),
          ),
          items: const [
            DropdownMenuItem(value: 'male', child: Text('Мужской')),
            DropdownMenuItem(value: 'female', child: Text('Женский')),
          ],
          onChanged: (v) => setState(() => _gender = v ?? 'male'),
        ),
        const SizedBox(height: 12),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.cake_outlined),
          title: const Text('День рождения'),
          subtitle: Text(birthLabel),
          trailing: const Icon(Icons.chevron_right),
          onTap: _pickBirthDate,
        ),
        const SizedBox(height: 24),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(Icons.palette_outlined, color: theme.colorScheme.primary),
          title: const Text('Оформление'),
          subtitle: const Text('Цвет темы приложения'),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  color: ref.watch(themeSeedProvider),
                  shape: BoxShape.circle,
                  border: Border.all(color: theme.colorScheme.outlineVariant),
                ),
              ),
              const SizedBox(width: 4),
              const Icon(Icons.chevron_right),
            ],
          ),
          onTap: () {
            Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => ThemeAppearanceScreen(
                  onApplied: widget.onStatusChanged,
                ),
              ),
            );
          },
        ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: _saving ? null : _saveProfile,
          child: _saving
              ? const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Сохранить'),
        ),
        const SizedBox(height: 24),
        OutlinedButton.icon(
          onPressed: _confirmLogout,
          icon: const Icon(Icons.logout),
          label: const Text('Выйти'),
        ),
        const SizedBox(height: 12),
        TextButton.icon(
          onPressed: _confirmDeleteAccount,
          icon: Icon(Icons.delete_forever_outlined, color: theme.colorScheme.error),
          label: Text(
            'Удалить профиль',
            style: TextStyle(color: theme.colorScheme.error),
          ),
        ),
      ],
    );
  }
}
