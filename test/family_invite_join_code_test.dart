import 'package:familychat_app/features/members/family_invite_share.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('formatJoinCode splits six digits', () {
    expect(FamilyInviteShare.formatJoinCode('482915'), '482 915');
    expect(FamilyInviteShare.formatJoinCode('482 915'), '482 915');
  });

  test('normalizeJoinCode keeps only digits', () {
    expect(FamilyInviteShare.normalizeJoinCode('482 915'), '482915');
    expect(FamilyInviteShare.normalizeJoinCode('48-29-15'), '482915');
  });
}
