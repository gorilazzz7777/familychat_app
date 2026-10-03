import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../tdlib_geo.dart';

export '../tdlib_geo.dart' show detectCountryIsoFromIp;

/// Country dial + national number mask for Telegram login.
class PhoneCountry {
  const PhoneCountry({
    required this.iso,
    required this.name,
    required this.dialCode,
    required this.flag,
    required this.mask,
  });

  final String iso;
  final String name;
  final String dialCode;
  final String flag;
  /// `#` = digit. Applied to national part only (without dial code).
  final String mask;

  int get maxNationalDigits => mask.split('').where((c) => c == '#').length;
}

const kPhoneCountries = <PhoneCountry>[
  PhoneCountry(
    iso: 'RU',
    name: 'Россия',
    dialCode: '7',
    flag: '🇷🇺',
    mask: '(###) ###-##-##',
  ),
  PhoneCountry(
    iso: 'BY',
    name: 'Беларусь',
    dialCode: '375',
    flag: '🇧🇾',
    mask: '## ###-##-##',
  ),
  PhoneCountry(
    iso: 'KZ',
    name: 'Казахстан',
    dialCode: '7',
    flag: '🇰🇿',
    mask: '(###) ###-##-##',
  ),
  PhoneCountry(
    iso: 'UA',
    name: 'Украина',
    dialCode: '380',
    flag: '🇺🇦',
    mask: '## ### ## ##',
  ),
  PhoneCountry(
    iso: 'AM',
    name: 'Армения',
    dialCode: '374',
    flag: '🇦🇲',
    mask: '## ######',
  ),
  PhoneCountry(
    iso: 'AZ',
    name: 'Азербайджан',
    dialCode: '994',
    flag: '🇦🇿',
    mask: '## ### ## ##',
  ),
  PhoneCountry(
    iso: 'GE',
    name: 'Грузия',
    dialCode: '995',
    flag: '🇬🇪',
    mask: '### ## ## ##',
  ),
  PhoneCountry(
    iso: 'UZ',
    name: 'Узбекистан',
    dialCode: '998',
    flag: '🇺🇿',
    mask: '## ###-##-##',
  ),
  PhoneCountry(
    iso: 'KG',
    name: 'Кыргызстан',
    dialCode: '996',
    flag: '🇰🇬',
    mask: '### ### ###',
  ),
  PhoneCountry(
    iso: 'TJ',
    name: 'Таджикистан',
    dialCode: '992',
    flag: '🇹🇯',
    mask: '## ### ####',
  ),
  PhoneCountry(
    iso: 'TM',
    name: 'Туркменистан',
    dialCode: '993',
    flag: '🇹🇲',
    mask: '## ######',
  ),
  PhoneCountry(
    iso: 'MD',
    name: 'Молдова',
    dialCode: '373',
    flag: '🇲🇩',
    mask: '#### ####',
  ),
  PhoneCountry(
    iso: 'TR',
    name: 'Турция',
    dialCode: '90',
    flag: '🇹🇷',
    mask: '(###) ### ## ##',
  ),
  PhoneCountry(
    iso: 'DE',
    name: 'Германия',
    dialCode: '49',
    flag: '🇩🇪',
    mask: '#### #######',
  ),
  PhoneCountry(
    iso: 'FR',
    name: 'Франция',
    dialCode: '33',
    flag: '🇫🇷',
    mask: '# ## ## ## ##',
  ),
  PhoneCountry(
    iso: 'GB',
    name: 'Великобритания',
    dialCode: '44',
    flag: '🇬🇧',
    mask: '#### ######',
  ),
  PhoneCountry(
    iso: 'US',
    name: 'США',
    dialCode: '1',
    flag: '🇺🇸',
    mask: '(###) ###-####',
  ),
  PhoneCountry(
    iso: 'CA',
    name: 'Канада',
    dialCode: '1',
    flag: '🇨🇦',
    mask: '(###) ###-####',
  ),
  PhoneCountry(
    iso: 'IL',
    name: 'Израиль',
    dialCode: '972',
    flag: '🇮🇱',
    mask: '##-###-####',
  ),
  PhoneCountry(
    iso: 'AE',
    name: 'ОАЭ',
    dialCode: '971',
    flag: '🇦🇪',
    mask: '## ### ####',
  ),
  PhoneCountry(
    iso: 'PL',
    name: 'Польша',
    dialCode: '48',
    flag: '🇵🇱',
    mask: '### ### ###',
  ),
  PhoneCountry(
    iso: 'CZ',
    name: 'Чехия',
    dialCode: '420',
    flag: '🇨🇿',
    mask: '### ### ###',
  ),
  PhoneCountry(
    iso: 'ES',
    name: 'Испания',
    dialCode: '34',
    flag: '🇪🇸',
    mask: '### ## ## ##',
  ),
  PhoneCountry(
    iso: 'IT',
    name: 'Италия',
    dialCode: '39',
    flag: '🇮🇹',
    mask: '### ### ####',
  ),
  PhoneCountry(
    iso: 'CN',
    name: 'Китай',
    dialCode: '86',
    flag: '🇨🇳',
    mask: '### #### ####',
  ),
  PhoneCountry(
    iso: 'IN',
    name: 'Индия',
    dialCode: '91',
    flag: '🇮🇳',
    mask: '##### #####',
  ),
  PhoneCountry(
    iso: 'TH',
    name: 'Таиланд',
    dialCode: '66',
    flag: '🇹🇭',
    mask: '## ### ####',
  ),
  PhoneCountry(
    iso: 'VN',
    name: 'Вьетнам',
    dialCode: '84',
    flag: '🇻🇳',
    mask: '## ### ## ##',
  ),
  PhoneCountry(
    iso: 'KR',
    name: 'Южная Корея',
    dialCode: '82',
    flag: '🇰🇷',
    mask: '##-####-####',
  ),
  PhoneCountry(
    iso: 'JP',
    name: 'Япония',
    dialCode: '81',
    flag: '🇯🇵',
    mask: '##-####-####',
  ),
];

PhoneCountry phoneCountryByIso(String iso) {
  final upper = iso.toUpperCase();
  return kPhoneCountries.firstWhere(
    (c) => c.iso == upper,
    orElse: () => kPhoneCountries.first,
  );
}

String localeCountryIsoFallback() {
  try {
    final name = WidgetsBinding.instance.platformDispatcher.locale.countryCode;
    if (name != null && name.length == 2) return name.toUpperCase();
  } catch (_) {}
  return 'RU';
}

String applyPhoneMask(String digits, String mask) {
  final buf = StringBuffer();
  var di = 0;
  for (var i = 0; i < mask.length && di < digits.length; i++) {
    final m = mask[i];
    if (m == '#') {
      buf.write(digits[di++]);
    } else {
      buf.write(m);
    }
  }
  return buf.toString();
}

String digitsOnly(String s) => s.replaceAll(RegExp(r'\D'), '');

/// E.164-ish for TDLib: +{dial}{national digits}.
String buildE164(PhoneCountry country, String nationalDigits) {
  var national = digitsOnly(nationalDigits);
  // RU/KZ: users often type leading 8/7 for the national trunk.
  if ((country.iso == 'RU' || country.iso == 'KZ') &&
      national.length == 11 &&
      (national.startsWith('8') || national.startsWith('7'))) {
    national = national.substring(1);
  }
  if (national.length > country.maxNationalDigits) {
    national = national.substring(0, country.maxNationalDigits);
  }
  return '+${country.dialCode}$national';
}

class _PhoneMaskFormatter extends TextInputFormatter {
  _PhoneMaskFormatter(this.mask);

  final String mask;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final digits = digitsOnly(newValue.text);
    final max = mask.split('').where((c) => c == '#').length;
    final clipped = digits.length > max ? digits.substring(0, max) : digits;
    final formatted = applyPhoneMask(clipped, mask);
    return TextEditingValue(
      text: formatted,
      selection: TextSelection.collapsed(offset: formatted.length),
    );
  }
}

/// Country flag selector + masked national number field.
class TelegramPhoneInput extends StatefulWidget {
  const TelegramPhoneInput({
    super.key,
    required this.onChanged,
    this.enabled = true,
  });

  final ValueChanged<String> onChanged;
  final bool enabled;

  @override
  State<TelegramPhoneInput> createState() => TelegramPhoneInputState();
}

class TelegramPhoneInputState extends State<TelegramPhoneInput> {
  late PhoneCountry _country;
  final _nationalCtrl = TextEditingController();
  final _searchCtrl = TextEditingController();
  bool _detecting = true;

  String get e164 => buildE164(_country, _nationalCtrl.text);

  @override
  void initState() {
    super.initState();
    _country = phoneCountryByIso(localeCountryIsoFallback());
    _nationalCtrl.addListener(_emit);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _detectCountry();
    });
  }

  @override
  void dispose() {
    _nationalCtrl.removeListener(_emit);
    _nationalCtrl.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  void _emit() => widget.onChanged(e164);

  Future<void> _detectCountry() async {
    final iso = await detectCountryIsoFromIp();
    if (!mounted) return;
    setState(() {
      _detecting = false;
      if (iso != null) {
        _country = phoneCountryByIso(iso);
      }
    });
    _emit();
  }

  Future<void> _pickCountry() async {
    if (!widget.enabled) return;
    _searchCtrl.clear();
    final picked = await showModalBottomSheet<PhoneCountry>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSheet) {
            final q = _searchCtrl.text.trim().toLowerCase();
            final list = kPhoneCountries.where((c) {
              if (q.isEmpty) return true;
              return c.name.toLowerCase().contains(q) ||
                  c.iso.toLowerCase().contains(q) ||
                  c.dialCode.contains(q);
            }).toList();
            return DraggableScrollableSheet(
              expand: false,
              initialChildSize: 0.75,
              minChildSize: 0.4,
              maxChildSize: 0.95,
              builder: (ctx, scroll) {
                return Column(
                  children: [
                    const SizedBox(height: 8),
                    Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Colors.grey.shade400,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                      child: TextField(
                        controller: _searchCtrl,
                        decoration: const InputDecoration(
                          hintText: 'Страна или код',
                          prefixIcon: Icon(LucideIcons.search),
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                        onChanged: (_) => setSheet(() {}),
                      ),
                    ),
                    Expanded(
                      child: ListView.builder(
                        controller: scroll,
                        itemCount: list.length,
                        itemBuilder: (ctx, i) {
                          final c = list[i];
                          final selected = c.iso == _country.iso &&
                              c.dialCode == _country.dialCode;
                          return ListTile(
                            leading: Text(c.flag, style: const TextStyle(fontSize: 28)),
                            title: Text(c.name),
                            subtitle: Text('+${c.dialCode}'),
                            trailing: selected
                                ? Icon(
                                    LucideIcons.check,
                                    color: Theme.of(ctx).colorScheme.primary,
                                  )
                                : null,
                            onTap: () => Navigator.pop(ctx, c),
                          );
                        },
                      ),
                    ),
                  ],
                );
              },
            );
          },
        );
      },
    );
    if (picked == null || !mounted) return;
    setState(() {
      _country = picked;
      // Re-apply mask for new country length.
      final digits = digitsOnly(_nationalCtrl.text);
      _nationalCtrl.value = TextEditingValue(
        text: applyPhoneMask(
          digits.length > picked.maxNationalDigits
              ? digits.substring(0, picked.maxNationalDigits)
              : digits,
          picked.mask,
        ),
        selection: TextSelection.collapsed(
          offset: applyPhoneMask(
            digits.length > picked.maxNationalDigits
                ? digits.substring(0, picked.maxNationalDigits)
                : digits,
            picked.mask,
          ).length,
        ),
      );
    });
    _emit();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InputDecorator(
      decoration: const InputDecoration(
        labelText: 'Номер телефона',
        border: OutlineInputBorder(),
      ),
      child: Row(
        children: [
          InkWell(
            onTap: widget.enabled ? _pickCountry : null,
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_detecting)
                    SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: scheme.primary,
                      ),
                    )
                  else
                    Text(_country.flag, style: const TextStyle(fontSize: 22)),
                  const SizedBox(width: 4),
                  Text(
                    '+${_country.dialCode}',
                    style: Theme.of(context).textTheme.bodyLarge,
                  ),
                  Icon(
                    LucideIcons.chevron_down,
                    size: 16,
                    color: scheme.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),
          Container(
            width: 1,
            height: 28,
            margin: const EdgeInsets.symmetric(horizontal: 8),
            color: scheme.outlineVariant,
          ),
          Expanded(
            child: TextField(
              controller: _nationalCtrl,
              enabled: widget.enabled,
              keyboardType: TextInputType.phone,
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[\d\s\-()]')),
                _PhoneMaskFormatter(_country.mask),
              ],
              decoration: InputDecoration(
                hintText: applyPhoneMask(
                  '9' * _country.maxNationalDigits,
                  _country.mask,
                ),
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                disabledBorder: InputBorder.none,
                errorBorder: InputBorder.none,
                focusedErrorBorder: InputBorder.none,
                filled: false,
                isDense: true,
                contentPadding: EdgeInsets.zero,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
