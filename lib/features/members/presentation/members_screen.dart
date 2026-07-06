import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers/app_providers.dart';

class MembersScreen extends ConsumerStatefulWidget {
  const MembersScreen({super.key});

  @override
  ConsumerState<MembersScreen> createState() => _MembersScreenState();
}

class _MembersScreenState extends ConsumerState<MembersScreen> {
  List<Map<String, dynamic>> _members = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final list = await ref.read(familychatRepositoryProvider).members();
      if (!mounted) return;
      setState(() {
        _members = list;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.builder(
        itemCount: _members.length,
        itemBuilder: (context, i) {
          final m = _members[i];
          return ListTile(
            leading: CircleAvatar(child: Text((m['display_name'] as String? ?? '?').characters.first)),
            title: Text(m['display_name']?.toString() ?? ''),
            subtitle: Text(m['kinship_label']?.toString() ?? ''),
            trailing: Text('Ур. ${m['kinship_level']}'),
          );
        },
      ),
    );
  }
}
