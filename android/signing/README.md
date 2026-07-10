# Подпись Android для RuStore (Family Chat)

## Быстрый старт

1. `pepk.jar` лежит в этой папке (или в `Downloads\pepk (4).jar` — скрипт подхватит).
2. В [консоли RuStore](https://console.rustore.ru) → приложение → **Подпись** → скопируйте **ключ шифрования** для PEPK.
3. Скопируйте `secrets.example.ps1` → `secrets.local.ps1`, укажите пароли и `$RuStoreEncryptionKey`.
4. Из корня `familychat_app`:

```powershell
powershell -ExecutionPolicy Bypass -File android/signing/generate-rustore-signing.ps1
```

5. В RuStore загрузите:
   - `android/signing/pepk_out.zip`
   - `android/signing/upload_certificate.pem`
6. Сохраните `android/signing/SAVE_TO_CLOUD.txt` и `familychat-release.keystore` в облако.
7. Сборка: `flutter build appbundle --release`

## Файлы

| Файл | Назначение |
|------|------------|
| `../familychat-release.keystore` | Ключ подписи (не в git) |
| `../key.properties` | Пароли для Gradle |
| `upload_certificate.pem` | Сертификат для консоли RuStore |
| `pepk_out.zip` | Экспорт upload-ключа для RuStore |
| `pepk.jar` | Утилита PEPK |

`keyAlias` для AAB: **upload**.
