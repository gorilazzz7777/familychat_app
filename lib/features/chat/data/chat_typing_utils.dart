String chatTypingSubtitle({
  required bool isDm,
  required List<String> displayNames,
}) {
  if (displayNames.isEmpty) return '';
  if (isDm) return 'пишет...';
  if (displayNames.length == 1) {
    return '${displayNames.first} пишет...';
  }
  if (displayNames.length == 2) {
    return '${displayNames[0]} и ${displayNames[1]} пишут...';
  }
  return '${displayNames.first} и ещё ${displayNames.length - 1} пишут...';
}
