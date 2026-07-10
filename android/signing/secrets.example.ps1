# Скопируйте в secrets.local.ps1 и заполните (secrets.local.ps1 в .gitignore).

$StorePassword = 'ВАШ_STORE_PASSWORD'
$KeyPassword = 'ВАШ_STORE_PASSWORD'
$KeyAlias = 'upload'
$Dn = 'CN=Family Chat, OU=Mobile, O=Family Chat, L=Moscow, ST=Moscow, C=RU'

# Ключ шифрования из консоли RuStore → Подпись → скачать подпись → «Скопировать» у команды PEPK
$RuStoreEncryptionKey = 'ВАШ_ENCRYPTION_KEY_ИЗ_КОНСОЛИ_RUSTORE'
