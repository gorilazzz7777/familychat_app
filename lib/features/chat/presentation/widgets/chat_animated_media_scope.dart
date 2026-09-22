import 'package:flutter/widgets.dart';

/// Управление autoplay GIF/стикеров в ленте чата.
///
/// Правила:
/// - до первого скролла: autoplay при первом показе (≥50% + settle);
/// - любой скролл: стоп всех, дальше только тап;
/// - тап: play/pause в пузыре до следующего скролла.
class ChatAnimatedMediaController extends ChangeNotifier {
  var suppressAutoplay = false;
  var isScrolling = false;
  var scrollGeneration = 0;

  void noteUserScroll() {
    final started = !isScrolling;
    isScrolling = true;
    if (!suppressAutoplay) {
      suppressAutoplay = true;
      scrollGeneration++;
      notifyListeners();
      return;
    }
    // После scroll-end пользователь мог снова запустить play тапом —
    // следующий жест скролла должен снова остановить.
    if (started) {
      scrollGeneration++;
      notifyListeners();
    }
  }

  void noteScrollEnd() {
    if (!isScrolling) return;
    isScrolling = false;
    notifyListeners();
  }
}

class ChatAnimatedMediaScope extends InheritedNotifier<ChatAnimatedMediaController> {
  const ChatAnimatedMediaScope({
    super.key,
    required ChatAnimatedMediaController controller,
    required super.child,
  }) : super(notifier: controller);

  static ChatAnimatedMediaController? maybeOf(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<ChatAnimatedMediaScope>()
        ?.notifier;
  }
}
