/// Колбэк из [ShellScreen] для фонового обновления вкладок без ручного pull-to-refresh.
class ShellRefresh {
  ShellRefresh._();

  static final ShellRefresh instance = ShellRefresh._();

  Future<void> Function({bool silent})? _refreshMainTabs;
  void Function(Map<String, dynamic> event)? _applyFeedEvent;

  void register(
    Future<void> Function({bool silent}) refreshMainTabs, {
    void Function(Map<String, dynamic> event)? applyFeedEvent,
  }) {
    _refreshMainTabs = refreshMainTabs;
    _applyFeedEvent = applyFeedEvent;
  }

  void unregister() {
    _refreshMainTabs = null;
    _applyFeedEvent = null;
  }

  Future<void> refreshMainTabs({bool silent = true}) async {
    await _refreshMainTabs?.call(silent: silent);
  }

  /// Сразу подставляет серверный feed-event (замена optimistic по batch_id).
  void applyFeedEvent(Map<String, dynamic> event) {
    _applyFeedEvent?.call(event);
  }
}
