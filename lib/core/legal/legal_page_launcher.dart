import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config/env.dart';

Future<void> openLegalDocumentPage(
  BuildContext context,
  String url,
) async {
  final uri = Uri.parse(url);
  final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
  if (!context.mounted || opened) return;
  ScaffoldMessenger.of(context).showSnackBar(
    const SnackBar(content: Text('Не удалось открыть ссылку')),
  );
}

Future<void> openFamilyChatPrivacyPolicy(BuildContext context) =>
    openLegalDocumentPage(context, Env.legalPrivacyUrl);

Future<void> openFamilyChatUserAgreement(BuildContext context) =>
    openLegalDocumentPage(context, Env.legalAgreementUrl);
