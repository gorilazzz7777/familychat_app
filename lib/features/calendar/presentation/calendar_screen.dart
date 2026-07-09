import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/widgets/family_app_bar.dart';
import 'calendar_event_edit_screen.dart';
import 'calendar_events_tab.dart';
import 'calendar_months_tab.dart';

class CalendarScreen extends ConsumerStatefulWidget {
  const CalendarScreen({super.key});

  @override
  ConsumerState<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends ConsumerState<CalendarScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  int _reloadToken = 0;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  void _bumpReload() => setState(() => _reloadToken++);

  Future<void> _createEvent() async {
    final now = DateTime.now();
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => CalendarEventEditScreen(initialDate: now),
      ),
    );
    if (changed == true) _bumpReload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: FamilyAppBar.build(
        title: 'Календарь',
        bottom: TabBar(
          controller: _tabs,
          tabs: const [
            Tab(text: 'События'),
            Tab(text: 'Месяцы'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        physics: const NeverScrollableScrollPhysics(),
        children: [
          CalendarEventsTab(reloadToken: _reloadToken),
          CalendarMonthsTab(reloadToken: _reloadToken),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _createEvent,
        icon: const Icon(Icons.add),
        label: const Text('Событие'),
      ),
    );
  }
}
