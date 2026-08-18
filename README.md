# Family VPN

Приватный Android-клиент для семейного VPN на одном VPS. Проект не содержит
ПК-режима, домашнего сервера, iOS-клиента и инфраструктуры для массового
сервиса.

## Возможности

- одна кнопка подключения к VPS;
- VLESS + REALITY через Xray;
- удалённый JSON-профиль и локальный fallback;
- проверка доступности туннеля;
- автоматическое переподключение к тому же VPS через резервные порты;
- восстановление последнего рабочего профиля после перезапуска приложения.

## Структура

- `lib/main.dart` — интерфейс, подключение и watchdog;
- `assets/vpn_profile.json` — встроенный резервный профиль;
- `android/` — Android-проект и настройки подписи;
- `scripts/build-release.ps1` — воспроизводимая release-сборка;
- `docs/server.md` — памятка по конфигурации VPS.

## Локальная сборка

Требуются Flutter stable, Android SDK и Java 17.

1. Скопировать `android/key.properties.example` в `android/key.properties`.
2. Указать путь и пароли постоянного release-ключа.
3. Выполнить:

```powershell
.\scripts\build-release.ps1
```

По умолчанию создаётся ARM64 APK для современных телефонов:

`build/app/outputs/flutter-apk/app-arm64-v8a-release.apk`

Универсальная сборка:

```powershell
.\scripts\build-release.ps1 -Target universal
```

## Рабочая конфигурация

- профиль: `https://sister.lucartmax.kz/profile.json`;
- VPS: `46.247.42.87`;
- порты Xray: `2053`, `8443`, `2083`, `2087`, `2096`;
- порт `443` принадлежит Caddy и не используется Xray напрямую.

## Безопасность

Репозиторий должен оставаться приватным. Не добавляйте в Git APK, AAB,
`android/key.properties`, JKS/keystore и резервные копии серверных конфигов.
Встроенный профиль содержит параметры доступа к семейному VPN; при утечке
репозитория или APK их необходимо заменить на VPS.
