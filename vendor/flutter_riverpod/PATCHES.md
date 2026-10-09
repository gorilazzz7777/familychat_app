# Patches on flutter_riverpod 2.6.1

## ConsumerStatefulElement (lib/src/consumer.dart)

1. Close `watch` / `listen` ProviderSubscriptions **before** `super.unmount()`.
   Upstream closes them after the element is already defunct, so a
   `ChangeNotifier.notifyListeners()` (e.g. TDLib) in that window calls
   `markNeedsBuild` and asserts `_lifecycleState != defunct`.

2. Guard the `watch` listener with `if (!mounted) return` before
   `markNeedsBuild()`.

## ChangeNotifierProviderElement (lib/src/change_notifier_provider/base.dart)

3. Do not call `notifier.dispose()` in `runOnDispose`. FamilyChat exposes
   `TelegramTdlibService.instance` (singleton); disposing it from
   ProviderScope would kill TDLib listeners mid-session.
