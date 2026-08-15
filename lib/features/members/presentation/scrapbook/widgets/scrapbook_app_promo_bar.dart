import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../../../core/config/env.dart';

/// Нижний баннер на публичном альбоме: «сделано в LittleOne» + RuStore.
class ScrapbookAppPromoBar extends StatelessWidget {
  const ScrapbookAppPromoBar({super.key});

  static const height = 64.0;

  Future<void> _openStore() async {
    final raw = Env.rustoreAppUrl.trim();
    if (raw.isEmpty) return;
    final uri = Uri.tryParse(raw);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    final hasStore = Env.rustoreAppUrl.trim().isNotEmpty;

    return Material(
      color: const Color(0xFF2C2118),
      elevation: 8,
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: height,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: Image.asset(
                    'assets/logo/logo.png',
                    width: 40,
                    height: 40,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => Container(
                      width: 40,
                      height: 40,
                      color: const Color(0xFF4A3728),
                      alignment: Alignment.center,
                      child: const Icon(
                        Icons.auto_stories_rounded,
                        color: Color(0xFFE6D5BC),
                        size: 22,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Сделано с помощью',
                        style: GoogleFonts.lato(
                          fontSize: 11,
                          color: const Color(0xFFBFA892),
                          height: 1.1,
                        ),
                      ),
                      Text(
                        'LittleOne: Дневник',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.lato(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: const Color(0xFFF5E6D3),
                          height: 1.2,
                        ),
                      ),
                    ],
                  ),
                ),
                if (hasStore)
                  FilledButton(
                    onPressed: _openStore,
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF0077FF),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    child: const Text(
                      'Скачать в RuStore',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
