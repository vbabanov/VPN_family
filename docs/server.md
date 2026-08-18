# VPS

Сервер используется несколькими проектами. Любые изменения портов и Caddy
нужно выполнять после проверки занятых сокетов и с резервной копией конфига.

## Сервисы

| Назначение | Сервис | Конфигурация |
| --- | --- | --- |
| VPN | `family-vpn-xray.service` | `/etc/family-vpn-xray/config.json` |
| HTTPS и маршрутизация | `caddy.service` | `/etc/caddy/Caddyfile` |
| Удалённый профиль | Caddy file server | `/srv/family-vpn/profile.json` |

Xray слушает `2053`, `8443`, `2083`, `2087`, `2096`. Порт `443` слушает
Caddy: на нём также работают другие проекты VPS.

## Проверка состояния

```bash
systemctl is-active family-vpn-xray caddy
ss -ltnup | grep -E ':(443|2053|8443|2083|2087|2096)\b'
curl --fail --silent --show-error https://sister.lucartmax.kz/profile.json >/dev/null
journalctl -u family-vpn-xray --since '10 minutes ago' --no-pager
```

## Безопасное применение изменений

1. Проверить занятые порты через `ss`.
2. Сделать резервную копию изменяемого конфига.
3. Для Caddy выполнить `caddy validate --config /etc/caddy/Caddyfile`.
4. Использовать `systemctl reload caddy`; restart применять только при необходимости.
5. Перезапустить Xray и проверить журнал, профиль и подключение телефона.

Не храните UUID клиента, REALITY private key, SSH-ключи и серверные резервные
копии в репозитории. Имя поддомена не является механизмом защиты: параметры
доступа необходимо менять после любой утечки профиля или APK.
