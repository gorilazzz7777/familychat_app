/// Web / unsupported: локальный Vosk недоступен — расшифровка пропускается (тихо).
class ChatVoiceTranscription {
  ChatVoiceTranscription._();
  static final ChatVoiceTranscription instance = ChatVoiceTranscription._();

  bool get supported => false;

  Future<void> preloadModelToDisk() async {}

  Future<void> ensureReady() async {}

  /// Распознать WAV/PCM 16 kHz mono. На web всегда `null`.
  Future<String?> transcribeWavBytes(List<int> bytes) async => null;
}
