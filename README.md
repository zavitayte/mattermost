# Mattermost — установка одной командой

Интерактивный установщик Mattermost: Docker, PostgreSQL, Nginx и SSL от Let's Encrypt.

## Установка

На чистом сервере с Ubuntu 22.04/24.04 выполните от root:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/zavitayte/mattermost/main/install.sh)
```

Скрипт спросит домен, e-mail, часовой пояс и дополнительные опции, покажет сводку и всё установит.

**Перед запуском** создайте A-запись домена на IP сервера.

## Что делает скрипт

- обновляет систему и при желании создаёт swap;
- настраивает файрвол UFW (SSH, 80, 443, 8443);
- ставит Docker;
- разворачивает официальный [mattermost/docker](https://github.com/mattermost/docker);
- выпускает SSL-сертификат и настраивает его автопродление;
- по желанию включает ежедневный бэкап базы и файлов.

Повторный запуск безопасен: существующие данные, пароль базы и сертификат сохраняются.

## Управление

```bash
cd /opt/mattermost
docker compose -f docker-compose.yml -f docker-compose.nginx.yml logs -f     # логи
docker compose -f docker-compose.yml -f docker-compose.nginx.yml restart     # перезапуск
mattermost-backup                                                            # бэкап вручную
```

### Обновление Mattermost

Поменяйте `MATTERMOST_IMAGE_TAG` в `/opt/mattermost/.env` и выполните:

```bash
docker compose -f docker-compose.yml -f docker-compose.nginx.yml pull
docker compose -f docker-compose.yml -f docker-compose.nginx.yml up -d
```
