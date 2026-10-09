/// Premium Services access payload from `/familychat/services/access/`.
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

class ServicesAccess {
  const ServicesAccess({
    required this.proxy,
    required this.register,
    required this.services,
  });

  final ServicesProxyConfig proxy;
  final ServicesRegisterConfig register;
  final List<ServiceItem> services;

  factory ServicesAccess.fromJson(Map<String, dynamic> json) {
    final proxyRaw = json['proxy'];
    final registerRaw = json['register'];
    final listRaw = json['services'];
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
    );
  }
}
