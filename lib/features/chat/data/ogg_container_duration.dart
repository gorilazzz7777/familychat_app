import 'dart:typed_data';

/// Длительность Ogg (Opus/Vorbis) по страницам контейнера, без нативного декодера.
/// Telegram шлёт голосовые как Opus в Ogg (`OggS` + `OpusHead`).
int? oggContainerDurationMs(List<int> bytes) {
  if (bytes.length < 27) return null;
  if (!_isOggS(bytes, 0)) return null;

  var offset = 0;
  var lastGranule = 0;
  var sampleRate = 0;
  var preSkip = 0;
  var opus = false;

  while (offset + 27 <= bytes.length) {
    if (!_isOggS(bytes, offset)) break;
    final granule = _readI64Le(bytes, offset + 6);
    final segmentCount = bytes[offset + 26];
    if (segmentCount < 0 || offset + 27 + segmentCount > bytes.length) break;

    var payloadSize = 0;
    for (var i = 0; i < segmentCount; i++) {
      payloadSize += bytes[offset + 27 + i];
    }
    final payloadStart = offset + 27 + segmentCount;
    if (payloadStart + payloadSize > bytes.length) break;

    if (sampleRate == 0 && payloadSize >= 8) {
      final head = payloadStart;
      if (_asciiAt(bytes, head, 'OpusHead') && payloadSize >= 16) {
        opus = true;
        sampleRate = 48000;
        preSkip = bytes[head + 10] | (bytes[head + 11] << 8);
      } else if (bytes[head] == 1 &&
          _asciiAt(bytes, head + 1, 'vorbis') &&
          payloadSize >= 16) {
        sampleRate = bytes[head + 12] |
            (bytes[head + 13] << 8) |
            (bytes[head + 14] << 16) |
            (bytes[head + 15] << 24);
      }
    }

    if (granule > 0) lastGranule = granule;
    offset = payloadStart + payloadSize;
  }

  if (lastGranule <= 0) return null;
  final rate = sampleRate > 0 ? sampleRate : (opus ? 48000 : 0);
  if (rate <= 0) return null;
  final samples = lastGranule - preSkip;
  if (samples <= 0) return null;
  return (samples * 1000 / rate).round();
}

bool bytesLookLikeOgg(List<int> bytes) =>
    bytes.length >= 4 && _isOggS(bytes, 0);

bool _isOggS(List<int> bytes, int offset) {
  return offset + 4 <= bytes.length &&
      bytes[offset] == 0x4F &&
      bytes[offset + 1] == 0x67 &&
      bytes[offset + 2] == 0x67 &&
      bytes[offset + 3] == 0x53;
}

bool _asciiAt(List<int> bytes, int offset, String ascii) {
  if (offset + ascii.length > bytes.length) return false;
  for (var i = 0; i < ascii.length; i++) {
    if (bytes[offset + i] != ascii.codeUnitAt(i)) return false;
  }
  return true;
}

int _readI64Le(List<int> bytes, int offset) {
  final data = ByteData.sublistView(
    bytes is Uint8List ? bytes : Uint8List.fromList(bytes),
    offset,
    offset + 8,
  );
  return data.getInt64(0, Endian.little);
}