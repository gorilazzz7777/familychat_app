String genderVerb(
  String gender, {
  required String male,
  required String female,
}) {
  return gender == 'female' ? female : male;
}

String actorGender(Map<String, dynamic>? actor) {
  final gender = actor?['gender']?.toString();
  if (gender == 'female') return 'female';
  return 'male';
}

String feedEventTitle({
  required String kind,
  required String actorName,
  required String gender,
  String? joinedName,
  int? photoCount,
}) {
  return switch (kind) {
    'message_sent' =>
      '$actorName ${genderVerb(gender, male: 'написал', female: 'написала')} в чате',
    'photo_uploaded' =>
      '$actorName ${genderVerb(gender, male: 'добавил', female: 'добавила')} фото',
    'photo_added_to_album' =>
      '$actorName ${genderVerb(gender, male: 'добавил', female: 'добавила')} фото в альбом',
    'photo_batch_uploaded' => () {
      final count = photoCount ?? 0;
      final action = genderVerb(gender, male: 'добавил', female: 'добавила');
      return '$actorName $action $count фото';
    }(),
    'media_liked' =>
      '$actorName ${genderVerb(gender, male: 'лайкнул', female: 'лайкнула')} фото',
    'media_commented' =>
      '$actorName ${genderVerb(gender, male: 'прокомментировал', female: 'прокомментировала')} фото',
    'member_joined' =>
      '${joinedName ?? actorName} ${genderVerb(gender, male: 'присоединился', female: 'присоединилась')} к семье',
    'profile_updated' =>
      '$actorName ${genderVerb(gender, male: 'обновил', female: 'обновила')} профиль',
    _ => 'Событие',
  };
}
