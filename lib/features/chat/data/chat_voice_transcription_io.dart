import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:vosk_flutter_service/vosk_flutter_service.dart';

const int _kSampleRate = 16000;
const String _kRuModelName = 'vosk-model-small-ru-0.22';
const String _kBundledZipAsset = 'assets/voice/vosk-model-small-ru-0.22.zip';

String? _textFromVoskJson(String raw) {
  final t = raw.trim();
  if (t.isEmpty || t == '{}') return null;
  try {
    final m = jsonDecode(t);
    if (m is! Map<String, dynamic>) return null;
    final text = (m['text'] as String?)?.trim();
    if (text != null && text.isNotEmpty) return text;
    final partial = (m['partial'] as String?)?.trim();
    if (partial != null && partial.isNotEmpty) return partial;
  } catch (_) {}
  return null;
}

/// Офлайн STT (Vosk) для голосовых сообщений: модель из assets, без сети.
class ChatVoiceTranscription {
  ChatVoiceTranscription._();
  static final ChatVoiceTranscription instance = ChatVoiceTranscription._();

  final VoskFlutterPlugin _vosk = VoskFlutterPlugin.instance();
  final ModelLoader _modelLoader = ModelLoader();

  Model? _model;
  Recognizer? _recognizer;
  Future<void>? _readyFuture;

  bool get supported => Platform.isAndroid || Platform.isIOS;

  Future<void> preloadModelToDisk() async {
    if (!supported) return;
    try {
      await _ensureModelOnDisk();
    } catch (_) {}
  }

  Future<void> ensureReady() async {
    if (!supported) return;
    _readyFuture ??= _loadModelAndRecognizer();
    await _readyFuture;
  }

  Future<void> _ensureModelOnDisk() async {
    if (await _modelLoader.isModelAlreadyLoaded(_kRuModelName)) return;
    await _modelLoader.loadFromAssets(_kBundledZipAsset);
  }

  Future<void> _loadModelAndRecognizer() async {
    if (_recognizer != null) return;
    await _ensureModelOnDisk();
    final modelDir = await _modelLoader.modelPath(_kRuModelName);
    _model = await _vosk.createModel(modelDir);
    final model = _model;
    if (model == null) return;
    _recognizer = await _vosk.createRecognizer(
      model: model,
      sampleRate: _kSampleRate,
    );
  }

  Future<String?> transcribeWavBytes(List<int> bytes) async {
    if (!supported || bytes.isEmpty) return null;
    try {
      await ensureReady();
      final recognizer = _recognizer;
      if (recognizer == null) return null;
      await recognizer.reset();
      await recognizer.acceptWaveformBytes(Uint8List.fromList(bytes));
      return _textFromVoskJson(await recognizer.getFinalResult());
    } catch (_) {
      return null;
    }
  }
}
