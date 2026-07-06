import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/providers/app_providers.dart';

class ChatInfoSheet extends ConsumerStatefulWidget {
  const ChatInfoSheet({
    super.key,
    required this.threadId,
    required this.title,
  });

  final int threadId;
  final String title;

  @override
  ConsumerState<ChatInfoSheet> createState() => _ChatInfoSheetState();
}

class _ChatInfoSheetState extends ConsumerState<ChatInfoSheet>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  List<Map<String, dynamic>> _media = [];
  List<Map<String, dynamic>> _files = [];
  List<Map<String, dynamic>> _links = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 3, vsync: this);
    _load();
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final repo = ref.read(familychatRepositoryProvider);
    try {
      final results = await Future.wait([
        repo.threadMedia(widget.threadId),
        repo.threadFiles(widget.threadId),
        repo.threadLinks(widget.threadId),
      ]);
      if (!mounted) return;
      setState(() {
        _media = results[0];
        _files = results[1];
        _links = results[2];
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _mute(String key) async {
    try {
      await ref.read(familychatRepositoryProvider).setThreadMute(widget.threadId, key);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(key == 'off' ? 'Уведомления включены' : 'Уведомления отключены')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Ошибка: $e')),
      );
    }
  }

  Future<void> _showMuteOptions() async {
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(title: const Text('1 час'), onTap: () { Navigator.pop(ctx); _mute('1h'); }),
            ListTile(title: const Text('4 часа'), onTap: () { Navigator.pop(ctx); _mute('4h'); }),
            ListTile(title: const Text('8 часов'), onTap: () { Navigator.pop(ctx); _mute('8h'); }),
            ListTile(title: const Text('24 часа'), onTap: () { Navigator.pop(ctx); _mute('24h'); }),
            ListTile(title: const Text('Навсегда'), onTap: () { Navigator.pop(ctx); _mute('forever'); }),
            ListTile(title: const Text('Включить уведомления'), onTap: () { Navigator.pop(ctx); _mute('off'); }),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.75,
        child: Column(
          children: [
            const SizedBox(height: 8),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey.shade400,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  Text(widget.title, style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: _showMuteOptions,
                    icon: const Icon(Icons.notifications_off_outlined),
                    label: const Text('Уведомления'),
                  ),
                ],
              ),
            ),
            TabBar(
              controller: _tabs,
              tabs: const [
                Tab(text: 'Галерея'),
                Tab(text: 'Ссылки'),
                Tab(text: 'Файлы'),
              ],
            ),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : TabBarView(
                      controller: _tabs,
                      children: [
                        _media.isEmpty
                            ? const Center(child: Text('Нет изображений'))
                            : GridView.builder(
                                padding: const EdgeInsets.all(8),
                                gridDelegate:
                                    const SliverGridDelegateWithFixedCrossAxisCount(
                                  crossAxisCount: 3,
                                  crossAxisSpacing: 4,
                                  mainAxisSpacing: 4,
                                ),
                                itemCount: _media.length,
                                itemBuilder: (_, i) {
                                  final url = _media[i]['file_url']?.toString() ?? '';
                                  return CachedNetworkImage(
                                    imageUrl: url,
                                    fit: BoxFit.cover,
                                  );
                                },
                              ),
                        _links.isEmpty
                            ? const Center(child: Text('Нет ссылок'))
                            : ListView.builder(
                                itemCount: _links.length,
                                itemBuilder: (_, i) {
                                  final url = _links[i]['url']?.toString() ?? '';
                                  return ListTile(
                                    title: Text(
                                      url,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    onTap: () => launchUrl(Uri.parse(url)),
                                  );
                                },
                              ),
                        _files.isEmpty
                            ? const Center(child: Text('Нет файлов'))
                            : ListView.builder(
                                itemCount: _files.length,
                                itemBuilder: (_, i) {
                                  final f = _files[i];
                                  return ListTile(
                                    leading: const Icon(Icons.insert_drive_file_outlined),
                                    title: Text(f['filename']?.toString() ?? 'Файл'),
                                    onTap: () {
                                      final url = f['file_url']?.toString();
                                      if (url != null) launchUrl(Uri.parse(url));
                                    },
                                  );
                                },
                              ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
