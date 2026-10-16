/// Services access payload from `/familychat/services/access/`.
class ServicesProxyConfig {
  const ServicesProxyConfig({
    required this.scheme,
    required this.host,
    required this.port,
  });

  final String scheme;
  final String host;
  final int port;

  String get proxyUrl => '$scheme://$host:$port';

  factory ServicesProxyConfig.fromJson(Map<String, dynamic> json) {
    return ServicesProxyConfig(
      scheme: (json['scheme']?.toString() ?? 'http').trim().isEmpty
          ? 'http'
          : json['scheme'].toString().trim(),
      host: json['host']?.toString().trim() ?? '',
      port: int.tryParse(json['port']?.toString() ?? '') ?? 0,
    );
  }
}

class ServicesRegisterConfig {
  const ServicesRegisterConfig({
    required this.url,
    required this.token,
  });

  final String url;
  final String token;

  factory ServicesRegisterConfig.fromJson(Map<String, dynamic> json) {
    return ServicesRegisterConfig(
      url: json['url']?.toString().trim() ?? '',
      token: json['token']?.toString().trim() ?? '',
    );
  }
}

class ServiceItem {
  const ServiceItem({
    required this.id,
    required this.title,
    required this.url,
  });

  final String id;
  final String title;
  final String url;

  factory ServiceItem.fromJson(Map<String, dynamic> json) {
    return ServiceItem(
      id: json['id']?.toString() ?? '',
      title: json['title']?.toString() ?? 'Сервис',
      url: json['url']?.toString() ?? '',
    );
  }
}

/// Soft promo notice while Services are free for everyone.
class ServicesPromo {
  const ServicesPromo({
    required this.active,
    required this.id,
    required this.notice,
  });

  final bool active;
  final String id;
  final String notice;

  static const inactive = ServicesPromo(
    active: false,
    id: '',
    notice: '',
  );

  /// Client fallback when API omits `promo` (older backend during rollout).
  static const openFallback = ServicesPromo(
    active: true,
    id: '1',
    notice:
        'Сейчас промо-период: сервисы доступны без ограничений. '
        'Позже раздел станет частью подписки.',
  );

  factory ServicesPromo.fromJson(Map<String, dynamic>? json) {
    if (json == null) return inactive;
    final active = json['active'] == true;
    if (!active) return inactive;
    final id = (json['id']?.toString() ?? '').trim();
    final notice = (json['notice']?.toString() ?? '').trim();
    return ServicesPromo(
      active: true,
      id: id.isEmpty ? '1' : id,
      notice: notice.isEmpty ? openFallback.notice : notice,
    );
  }
}

class ServicesAccess {
  const ServicesAccess({
    required this.proxy,
    required this.register,
    required this.services,
    this.promo = ServicesPromo.inactive,
  });

  final ServicesProxyConfig proxy;
  final ServicesRegisterConfig register;
  final List<ServiceItem> services;
  final ServicesPromo promo;

  factory ServicesAccess.fromJson(Map<String, dynamic> json) {
    final proxyRaw = json['proxy'];
    final registerRaw = json['register'];
    final listRaw = json['services'];
    final promoRaw = json['promo'];
    final hasPromoKey = json.containsKey('promo');
    return ServicesAccess(
      proxy: ServicesProxyConfig.fromJson(
        proxyRaw is Map
            ? Map<String, dynamic>.from(proxyRaw)
            : const <String, dynamic>{},
      ),
      register: ServicesRegisterConfig.fromJson(
        registerRaw is Map
            ? Map<String, dynamic>.from(registerRaw)
            : const <String, dynamic>{},
      ),
      services: [
        for (final item in (listRaw is List ? listRaw : const []))
          if (item is Map)
            ServiceItem.fromJson(Map<String, dynamic>.from(item)),
      ],
      // Older backends without `promo`: treat as open promo while client
      // already shows the tab to everyone.
      promo: hasPromoKey
          ? ServicesPromo.fromJson(
              promoRaw is Map
                  ? Map<String, dynamic>.from(promoRaw)
                  : null,
            )
          : ServicesPromo.openFallback,
    );
  }
}
