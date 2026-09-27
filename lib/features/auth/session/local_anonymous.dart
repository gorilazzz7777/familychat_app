/// Local-anonymous Family Space session: in-app without server User.
///
/// [user_id] is [kLocalAnonymousUserId] until [ensureMaterializedSession]
/// creates a real guest via `auth/guest/`.
library;

const int kLocalAnonymousUserId = 0;

const String kLocalAnonymousFlag = 'local_anonymous';

/// Synthetic status so bootstrap can open onboarding without JWT.
Map<String, dynamic> localAnonymousStatus() {
  return <String, dynamic>{
    'user_id': kLocalAnonymousUserId,
    kLocalAnonymousFlag: true,
    'first_name': '',
    'last_name': '',
    'gender': '',
    'avatar_url': '',
    'birth_date': null,
    'birthday_display': null,
    'birthday_show_year': true,
    'suggest_face_tagging': true,
    'theme_seed_color': '',
    'display_name': 'Гость',
    'has_family': false,
    'onboarding_complete': false,
    'is_guest': true,
    'family_id': null,
    'family_name': '',
    'entitlements': <String, dynamic>{
      'individual_premium': false,
      'family_premium': false,
    },
    'telegram': <String, dynamic>{
      'connected': false,
      'status': '',
    },
  };
}

bool isLocalAnonymousStatus(Map<String, dynamic>? status) {
  if (status == null) return false;
  if (status[kLocalAnonymousFlag] == true) return true;
  final id = status['user_id'];
  final userId = id is int ? id : int.tryParse('$id');
  return userId == kLocalAnonymousUserId;
}
