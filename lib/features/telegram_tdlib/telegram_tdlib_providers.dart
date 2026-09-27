import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'telegram_tdlib_service.dart';

final telegramTdlibServiceProvider = ChangeNotifierProvider<TelegramTdlibService>(
  (ref) => TelegramTdlibService.instance,
);
