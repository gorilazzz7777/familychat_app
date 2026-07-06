import 'package:flutter/material.dart';

import '../features/chat/presentation/family_chat_screen.dart';
import '../features/members/presentation/members_screen.dart';

class ShellScreen extends StatefulWidget {
  const ShellScreen({super.key, required this.onLogout});

  final VoidCallback onLogout;

  @override
  State<ShellScreen> createState() => _ShellScreenState();
}

class _ShellScreenState extends State<ShellScreen> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_index == 0 ? 'Семейный чат' : 'Участники'),
        actions: [
          IconButton(onPressed: widget.onLogout, icon: const Icon(Icons.logout)),
        ],
      ),
      body: IndexedStack(
        index: _index,
        children: const [
          FamilyChatScreen(),
          MembersScreen(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.chat_outlined), label: 'Чат'),
          NavigationDestination(icon: Icon(Icons.people_outline), label: 'Семья'),
        ],
      ),
    );
  }
}
