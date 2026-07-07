/// Колбэк из [ShellScreen] для фонового обновления вкладок без ручного pull-to-refresh.
class ShellRefresh {
  ShellRefresh._();

  static final ShellRefresh instance = ShellRefresh._();

  Future<void> Function({bool silent})? _refreshMainTabs;

  void register(Future<void> Function({bool silent}) refreshMainTabs) {
    _refreshMainTabs = refreshMainTabs;
  }

  void unregister() {
    _refreshMainTabs = null;
  }

  Future<void> refreshMainTabs({bool silent = true}) async {
    await _refreshMainTabs?.call(silent: silent);
  }
}
