#!/usr/bin/env bash
# =============================================================================
#  Mattermost — установка одной командой
#  Docker + PostgreSQL + Nginx + Let's Encrypt
#
#  Запуск:
#    bash <(curl -fsSL https://raw.githubusercontent.com/zavitayte/mattermost/main/install.sh)
#  или
#    git clone https://github.com/zavitayte/mattermost && sudo bash mattermost/install.sh
# =============================================================================
set -Eeuo pipefail

# ---------- Настройки автора (можно менять) ----------------------------------
AUTHOR_NAME="MAGIC"
AUTHOR_URL="https://mglnk.store"
MM_DOCKER_REPO="https://github.com/mattermost/docker"
# Проверенная версия mattermost/docker (Mattermost 11.7.0). Чтобы обновить —
# поменяйте хеш на свежий коммит и проверьте установку на тестовом сервере.
MM_DOCKER_COMMIT="497414659ee7127677d2b91b44bb4f3ea9d14695"

# ---------- Цвета и вывод ------------------------------------------------------
if [[ -t 1 ]]; then
  C_RESET=$'\e[0m'; C_BOLD=$'\e[1m'; C_DIM=$'\e[2m'
  C_RED=$'\e[31m'; C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'
  C_BLUE=$'\e[34m'; C_MAGENTA=$'\e[35m'; C_CYAN=$'\e[36m'
else
  C_RESET=; C_BOLD=; C_DIM=; C_RED=; C_GREEN=; C_YELLOW=; C_BLUE=; C_MAGENTA=; C_CYAN=
fi

info() { echo "${C_BLUE}[•]${C_RESET} $*"; }
ok()   { echo "${C_GREEN}[✓]${C_RESET} $*"; }
warn() { echo "${C_YELLOW}[!]${C_RESET} $*"; }
die()  { echo "${C_RED}[✗]${C_RESET} $*" >&2; exit 1; }

STEP=0
step() { STEP=$((STEP + 1)); echo; echo "${C_BOLD}${C_MAGENTA}==> Шаг ${STEP}. $*${C_RESET}"; }

trap 'echo "${C_RED}[✗]${C_RESET} Ошибка в строке $LINENO (команда: $BASH_COMMAND). Установка прервана." >&2' ERR

# ---------- Логотип ------------------------------------------------------------
show_logo() {
  clear 2>/dev/null || true
  echo "${C_CYAN}${C_BOLD}"
  cat <<'EOF'
   ███╗   ███╗ █████╗  ██████╗ ██╗ ██████╗
   ████╗ ████║██╔══██╗██╔════╝ ██║██╔════╝
   ██╔████╔██║███████║██║  ███╗██║██║
   ██║╚██╔╝██║██╔══██║██║   ██║██║██║
   ██║ ╚═╝ ██║██║  ██║╚██████╔╝██║╚██████╗
   ╚═╝     ╚═╝╚═╝  ╚═╝ ╚═════╝ ╚═╝ ╚═════╝
EOF
  echo "${C_RESET}"
  echo "   ${C_BOLD}Mattermost Installer${C_RESET}  ${C_DIM}by ${AUTHOR_NAME} · ${AUTHOR_URL}${C_RESET}"
  echo "   ${C_DIM}Docker · PostgreSQL · Nginx · Let's Encrypt${C_RESET}"
  echo
}

# ---------- Ввод (работает и при запуске через curl | bash) --------------------
ask() { # ask VAR "Вопрос" "значение по умолчанию"
  local __var=$1 __prompt=$2 __def=${3:-} __ans
  if [[ -n $__def ]]; then
    read -r -p "${C_CYAN}?${C_RESET} ${__prompt} ${C_DIM}[${__def}] (Enter — оставить по умолчанию)${C_RESET}: " __ans </dev/tty
  else
    read -r -p "${C_CYAN}?${C_RESET} ${__prompt}: " __ans </dev/tty
  fi
  printf -v "$__var" '%s' "${__ans:-$__def}"
}

ask_yn() { # ask_yn "Вопрос" y|n   → код 0 = да
  local __def=$2 __ans __hint __enter
  if [[ $__def == y ]]; then __hint="Y/n"; __enter="да"; else __hint="y/N"; __enter="нет"; fi
  while true; do
    read -r -p "${C_CYAN}?${C_RESET} $1 ${C_DIM}[${__hint}] (Enter — ${__enter})${C_RESET}: " __ans </dev/tty
    __ans=${__ans:-$__def}
    case ${__ans,,} in
      y|yes|д|да)  return 0 ;;
      n|no|нет)    return 1 ;;
      *) warn "Введите y (да) или n (нет). Проверьте раскладку клавиатуры." ;;
    esac
  done
}

ask_secret() { # ask_secret VAR "Вопрос"
  local __var=$1 __ans
  read -r -s -p "${C_CYAN}?${C_RESET} $2: " __ans </dev/tty; echo
  printf -v "$__var" '%s' "$__ans"
}

# ---------- Работа с .env ------------------------------------------------------
# Заменяет первую строку KEY= (в том числе закомментированную), удаляет дубли,
# а если ключа нет, добавляет его в конец.
set_env() {
  local key=$1 val=$2
  if grep -qE "^[#[:space:]]*${key}=" .env; then
    awk -v k="$key" -v v="$val" '
      $0 ~ "^[#[:space:]]*" k "=" { if (!done) { print k "=" v; done = 1 }; next }
      { print }' .env > .env.tmp && mv .env.tmp .env
  else
    echo "${key}=${val}" >> .env
  fi
}
get_env() { grep -E "^$1=" .env 2>/dev/null | tail -n1 | cut -d= -f2- || true; }

# =============================================================================
main() {
  show_logo

  # ---------- Проверки ----------
  [[ $EUID -eq 0 ]] || die "Запустите от root: sudo bash install.sh"
  [[ -r /dev/tty ]] || die "Нужен интерактивный терминал."

  # shellcheck disable=SC1091
  . /etc/os-release
  if [[ ${ID:-} != ubuntu && ${ID:-} != debian ]]; then
    warn "Скрипт рассчитан на Ubuntu/Debian, у вас: ${PRETTY_NAME:-неизвестно}."
    ask_yn "Всё равно продолжить?" n || exit 1
  else
    ok "Система: ${PRETTY_NAME}"
  fi

  local mem_mb cpu
  mem_mb=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
  cpu=$(nproc)
  ok "Ресурсы: ${cpu} CPU, ${mem_mb} МБ RAM"

  # ---------- Вопросы ----------
  echo
  echo "${C_BOLD}Ответьте на несколько вопросов.${C_RESET}"
  echo "${C_DIM}Значение по умолчанию указано в [скобках] — чтобы его оставить, просто нажмите Enter.${C_RESET}"
  echo

  local DOMAIN EMAIL TZ_NAME INSTALL_DIR
  while true; do
    ask DOMAIN "Домен для Mattermost" "${MM_DOMAIN:-}"
    DOMAIN=${DOMAIN,,}
    [[ $DOMAIN =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,}$ ]] && break
    warn "Некорректный домен, попробуйте ещё раз."
  done

  while true; do
    ask EMAIL "E-mail для Let's Encrypt (уведомления о сертификате)" "${MM_EMAIL:-}"
    [[ $EMAIL =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] && break
    warn "Некорректный e-mail."
  done

  echo "${C_DIM}  Часовой пояс пишется как Регион/Город латиницей, например:"
  echo "  Europe/Moscow, Europe/Samara, Asia/Yekaterinburg, Asia/Novosibirsk, Asia/Vladivostok, UTC${C_RESET}"
  while true; do
    ask TZ_NAME "Часовой пояс сервера" "Europe/Moscow"
    [[ $TZ_NAME =~ ^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)*$ && -f /usr/share/zoneinfo/$TZ_NAME ]] && break
    warn "Пояс «${TZ_NAME}» не найден. Регистр важен: Europe/Moscow, а не europe/moscow."
    warn "Полный список: timedatectl list-timezones"
  done

  ask INSTALL_DIR "Папка установки" "/opt/mattermost"

  # Редакция Mattermost. При повторном запуске по умолчанию — текущая.
  local MM_IMAGE cur_image
  cur_image=$(grep -E '^MATTERMOST_IMAGE=' "$INSTALL_DIR/.env" 2>/dev/null | tail -n1 | cut -d= -f2- || true)
  echo
  echo "${C_BOLD}Редакция Mattermost${C_RESET} (обе бесплатные):"
  echo "  1) Team       — открытый код, без лимита на историю сообщений, до 250 пользователей"
  echo "  2) Enterprise — больше функций (Boards, Playbooks, SSO), но видны только"
  echo "                  последние 10 000 сообщений; лимит снимается платной лицензией"
  local ed_def=1
  [[ $cur_image == mattermost-enterprise-edition ]] && ed_def=2
  while true; do
    local ed
    ask ed "Выберите 1 или 2" "$ed_def"
    case $ed in
      1) MM_IMAGE=mattermost-team-edition; break ;;
      2) MM_IMAGE=mattermost-enterprise-edition; break ;;
      *) warn "Введите 1 или 2." ;;
    esac
  done
  echo

  local SET_RU=n
  ask_yn "Сделать русский языком интерфейса по умолчанию?" y && SET_RU=y

  # Почта: нужна для приглашений, сброса пароля и уведомлений.
  local DO_SMTP=n SMTP_HOST= SMTP_PORT= SMTP_USER= SMTP_PASS= SMTP_FROM=
  echo "${C_DIM}  Почта нужна для приглашений, сброса пароля и уведомлений. Можно настроить позже"
  echo "  в Системной консоли → Окружение → SMTP.${C_RESET}"
  if ask_yn "Настроить отправку почты (SMTP) сейчас?" n; then
    DO_SMTP=y
    while true; do
      ask SMTP_HOST "SMTP-сервер (например smtp.site.com)"
      [[ $SMTP_HOST =~ ^[A-Za-z0-9.-]+$ ]] && break
      warn "Укажите адрес сервера."
    done
    while true; do
      ask SMTP_PORT "Порт (465 — SSL/TLS, 587 — STARTTLS)" "465"
      [[ $SMTP_PORT =~ ^[0-9]+$ ]] && break
      warn "Порт — это число."
    done
    while true; do
      ask SMTP_USER "Логин (обычно это адрес почты, например mail@site.com)"
      [[ -n $SMTP_USER ]] && break
    done
    ask_secret SMTP_PASS "Пароль (у многих почтовых сервисов нужен «пароль приложения»; ввод скрыт)"
    ask SMTP_FROM "Адрес отправителя" "$SMTP_USER"
  fi

  local DO_UPGRADE=n DO_UFW=n DO_SWAP=n DO_BACKUP=n BACKUP_KEEP=7
  ask_yn "Обновить пакеты системы (apt upgrade)?" y && DO_UPGRADE=y
  ask_yn "Настроить файрвол UFW (SSH, 80, 443, 8443)?" y && DO_UFW=y
  if (( mem_mb < 3500 )) && ! swapon --show | grep -q .; then
    ask_yn "RAM меньше 4 ГБ и swap нет. Создать swap 2 ГБ?" y && DO_SWAP=y
  fi
  if ask_yn "Включить ежедневный бэкап (база + файлы)?" y; then
    DO_BACKUP=y
    ask BACKUP_KEEP "Сколько дней хранить бэкапы" "7"
    [[ $BACKUP_KEEP =~ ^[0-9]+$ ]] && (( BACKUP_KEEP >= 1 )) || BACKUP_KEEP=7
  fi

  # ---------- Проверка DNS ----------
  echo
  info "Проверяю DNS..."
  local server_ip domain_ip
  server_ip=$(curl -4 -fsS --max-time 6 https://api.ipify.org 2>/dev/null || true)
  domain_ip=$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk 'NR==1 {print $1}' || true)
  if [[ -z $domain_ip ]]; then
    warn "Домен ${DOMAIN} пока не резолвится. Создайте A-запись на ${server_ip:-IP сервера}."
    ask_yn "Продолжить без проверки? (сертификат может не выпуститься)" n || exit 1
  elif [[ -n $server_ip && $domain_ip != "$server_ip" ]]; then
    warn "${DOMAIN} указывает на ${domain_ip}, а IP сервера ${server_ip}."
    ask_yn "Продолжить всё равно?" n || exit 1
  else
    ok "${DOMAIN} → ${domain_ip}"
  fi

  if [[ $DO_SMTP == y ]]; then
    if timeout 6 bash -c "exec 3<>/dev/tcp/${SMTP_HOST}/${SMTP_PORT}" 2>/dev/null; then
      ok "SMTP ${SMTP_HOST}:${SMTP_PORT} доступен"
    else
      warn "Не удалось подключиться к ${SMTP_HOST}:${SMTP_PORT}. Возможно, хостинг блокирует"
      warn "исходящую почту — уточните в поддержке. Настройки всё равно будут сохранены."
    fi
  fi

  if ss -ltnH '( sport = :80 or sport = :443 )' 2>/dev/null | grep -q . \
     && ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q nginx; then
    warn "Порты 80/443 уже заняты другим процессом:"
    ss -ltnpH '( sport = :80 or sport = :443 )' || true
    ask_yn "Продолжить? (установка, скорее всего, не сможет занять порты)" n || exit 1
  fi

  # ---------- Сводка ----------
  echo
  echo "${C_BOLD}Будет установлено:${C_RESET}"
  echo "  Домен:          https://${DOMAIN}"
  echo "  E-mail:         ${EMAIL}"
  echo "  Часовой пояс:   ${TZ_NAME}"
  echo "  Папка:          ${INSTALL_DIR}"
  echo "  Редакция:       $([[ $MM_IMAGE == mattermost-team-edition ]] && echo Team || echo Enterprise)"
  echo "  Русский язык:   ${SET_RU}"
  echo "  Почта (SMTP):   $([[ $DO_SMTP == y ]] && echo "${SMTP_HOST}:${SMTP_PORT}, от ${SMTP_FROM}" || echo n)"
  echo "  apt upgrade:    ${DO_UPGRADE}"
  echo "  Файрвол UFW:    ${DO_UFW}"
  echo "  Swap 2 ГБ:      ${DO_SWAP}"
  echo "  Бэкап:          ${DO_BACKUP}$([[ $DO_BACKUP == y ]] && echo " (хранить ${BACKUP_KEEP} дн.)")"
  echo
  ask_yn "Начинаем установку?" y || { info "Отменено."; exit 0; }

  export DEBIAN_FRONTEND=noninteractive
  local START_TS=$SECONDS

  # ---------- 1. Система ----------
  step "Подготовка системы"
  timedatectl set-timezone "$TZ_NAME" 2>/dev/null || true
  apt-get update -y
  if [[ $DO_UPGRADE == y ]]; then
    apt-get -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold upgrade -y
  fi
  apt-get install -y git curl ca-certificates openssl cron jq
  [[ $DO_UFW == y ]] && apt-get install -y ufw
  ok "Пакеты установлены"

  if [[ $DO_SWAP == y ]]; then
    fallocate -l 2G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=2048
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null
    swapon /swapfile
    grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
    ok "Swap 2 ГБ создан"
  fi

  # ---------- 2. Файрвол ----------
  if [[ $DO_UFW == y ]]; then
    step "Файрвол"
    local ssh_port
    ssh_port=$(awk '{print $4}' <<< "${SSH_CONNECTION:-}")
    [[ -n $ssh_port ]] || ssh_port=$(sshd -T 2>/dev/null | awk '/^port / {print $2; exit}' || true)
    [[ -n $ssh_port ]] || ssh_port=22
    ufw allow "${ssh_port}/tcp" comment 'SSH' >/dev/null
    ufw allow 80/tcp   comment 'HTTP'  >/dev/null
    ufw allow 443/tcp  comment 'HTTPS' >/dev/null
    ufw allow 8443/udp comment 'Mattermost Calls' >/dev/null
    ufw allow 8443/tcp comment 'Mattermost Calls' >/dev/null
    ufw --force enable >/dev/null
    ok "UFW включён (SSH на порту ${ssh_port})"
  fi

  # ---------- 3. Docker ----------
  step "Docker"
  if command -v docker >/dev/null 2>&1; then
    ok "Docker уже установлен: $(docker -v)"
  else
    curl -fsSL https://get.docker.com | sh
    ok "Docker установлен"
  fi
  systemctl enable --now docker >/dev/null 2>&1 || true
  docker compose version >/dev/null 2>&1 || die "Не найден docker compose."

  # ---------- 4. Mattermost ----------
  step "Загрузка и настройка Mattermost"
  if [[ -d $INSTALL_DIR/.git ]]; then
    warn "Папка ${INSTALL_DIR} уже есть, использую её (повторный запуск)."
  else
    mkdir -p "$INSTALL_DIR"
    git -C "$INSTALL_DIR" init -q
    git -C "$INSTALL_DIR" remote add origin "$MM_DOCKER_REPO"
    git -C "$INSTALL_DIR" fetch -q --depth 1 origin "$MM_DOCKER_COMMIT" \
      || { rm -rf "$INSTALL_DIR/.git"; die "Не удалось скачать mattermost/docker. Проверьте интернет и запустите снова."; }
    git -C "$INSTALL_DIR" checkout -q FETCH_HEAD
    ok "Загружен mattermost/docker (версия ${MM_DOCKER_COMMIT:0:7})"
  fi
  cd "$INSTALL_DIR"

  local PG_PASS
  if [[ -f .env ]]; then
    PG_PASS=$(get_env POSTGRES_PASSWORD)
    info "Найден существующий .env, пароль базы сохраняю."
  else
    cp env.example .env
    PG_PASS=$(openssl rand -hex 24)
  fi
  [[ -n $PG_PASS && $PG_PASS != mmuser_password ]] || PG_PASS=$(openssl rand -hex 24)

  set_env DOMAIN "$DOMAIN"
  set_env TZ "$TZ_NAME"
  set_env POSTGRES_PASSWORD "$PG_PASS"
  set_env CERT_PATH "./certs/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
  set_env KEY_PATH  "./certs/etc/letsencrypt/live/${DOMAIN}/privkey.pem"
  set_env MATTERMOST_IMAGE "$MM_IMAGE"
  # Чтобы в папке установки работали короткие команды: docker compose logs -f и т.п.
  set_env COMPOSE_FILE "docker-compose.yml:docker-compose.nginx.yml"
  chmod 600 .env
  ok ".env настроен"

  mkdir -p ./volumes/app/mattermost/{config,data,logs,plugins,client/plugins,bleve-indexes}
  chown -R 2000:2000 ./volumes/app/mattermost
  ok "Папки данных созданы"

  local COMPOSE=(docker compose -f docker-compose.yml -f docker-compose.nginx.yml)

  # ---------- 5. SSL ----------
  step "SSL-сертификат Let's Encrypt"
  local CERT_FILE="certs/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
  if [[ -f $CERT_FILE ]]; then
    ok "Сертификат уже есть"
  else
    "${COMPOSE[@]}" down >/dev/null 2>&1 || true
    docker run --rm --name certbot -p 80:80 \
      -v "${INSTALL_DIR}/certs/etc/letsencrypt:/etc/letsencrypt" \
      -v "${INSTALL_DIR}/certs/lib/letsencrypt:/var/lib/letsencrypt" \
      certbot/certbot certonly --standalone --non-interactive --agree-tos \
      -m "$EMAIL" -d "$DOMAIN" \
      || die "Не удалось выпустить сертификат. Проверьте A-запись домена и что порт 80 открыт, затем запустите скрипт снова."
    ok "Сертификат выпущен"
  fi

  # Автопродление: раз в неделю проверяем срок; nginx останавливается
  # на несколько секунд, только если до истечения меньше 30 дней.
  cat > /usr/local/bin/mattermost-renew-cert <<EOF
#!/usr/bin/env bash
set -euo pipefail
cd "${INSTALL_DIR}"
CERT="certs/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
if openssl x509 -checkend \$((30*86400)) -noout -in "\$CERT" >/dev/null; then
  echo "\$(date '+%F %T') сертификат ещё действителен"; exit 0
fi
docker compose -f docker-compose.yml -f docker-compose.nginx.yml stop nginx
docker run --rm -p 80:80 \\
  -v "${INSTALL_DIR}/certs/etc/letsencrypt:/etc/letsencrypt" \\
  -v "${INSTALL_DIR}/certs/lib/letsencrypt:/var/lib/letsencrypt" \\
  certbot/certbot renew --standalone --non-interactive || true
docker compose -f docker-compose.yml -f docker-compose.nginx.yml start nginx
echo "\$(date '+%F %T') продление выполнено"
EOF
  chmod +x /usr/local/bin/mattermost-renew-cert
  echo "17 4 * * 1 root /usr/local/bin/mattermost-renew-cert >> /var/log/mattermost-renew.log 2>&1" \
    > /etc/cron.d/mattermost-renew
  ok "Автопродление сертификата настроено"

  # ---------- 6. Запуск ----------
  step "Запуск контейнеров"
  "${COMPOSE[@]}" pull
  "${COMPOSE[@]}" up -d
  info "Жду, пока Mattermost запустится (до 5 минут)..."
  local ready=n
  for _ in $(seq 1 60); do
    if curl -fsS --max-time 5 --resolve "${DOMAIN}:443:127.0.0.1" \
         "https://${DOMAIN}/api/v4/system/ping" >/dev/null 2>&1; then
      ready=y; break
    fi
    printf '.'; sleep 5
  done
  echo
  if [[ $ready == y ]]; then
    ok "Mattermost отвечает"
  else
    warn "Mattermost пока не ответил. Логи: cd ${INSTALL_DIR} && docker compose logs -f"
  fi

  # ---------- Язык и почта (пишем в config.json, чтобы их можно было менять в консоли) ----------
  if [[ $SET_RU == y || $DO_SMTP == y ]]; then
    step "Язык и почта"
    local CFG=volumes/app/mattermost/config/config.json
    if [[ -f $CFG ]]; then
      local smtp_sec=""
      [[ $SMTP_PORT == 465 ]] && smtp_sec=TLS
      [[ $SMTP_PORT == 587 ]] && smtp_sec=STARTTLS
      "${COMPOSE[@]}" stop mattermost >/dev/null
      MM_SMTP_PASS="$SMTP_PASS" \
      jq --arg ru "$SET_RU" --arg smtp "$DO_SMTP" \
         --arg host "$SMTP_HOST" --arg port "$SMTP_PORT" --arg user "$SMTP_USER" \
         --arg from "$SMTP_FROM" --arg sec "$smtp_sec" '
        (if $ru == "y" then
           .LocalizationSettings.DefaultServerLocale = "ru"
           | .LocalizationSettings.DefaultClientLocale = "ru"
         else . end)
        | (if $smtp == "y" then
           .EmailSettings.SendEmailNotifications = true
           | .EmailSettings.EnableSMTPAuth = true
           | .EmailSettings.SMTPServer = $host
           | .EmailSettings.SMTPPort = $port
           | .EmailSettings.SMTPUsername = $user
           | .EmailSettings.SMTPPassword = env.MM_SMTP_PASS
           | .EmailSettings.ConnectionSecurity = $sec
           | .EmailSettings.FeedbackEmail = $from
           | .EmailSettings.ReplyToAddress = $from
         else . end)' "$CFG" > "$CFG.tmp"
      cat "$CFG.tmp" > "$CFG" && rm -f "$CFG.tmp"   # cat сохраняет владельца и права файла
      "${COMPOSE[@]}" start mattermost >/dev/null
      if [[ $SET_RU == y ]]; then ok "Русский язык установлен по умолчанию"; fi
      if [[ $DO_SMTP == y ]]; then
        ok "Почта настроена. Проверить: Системная консоль → SMTP → «Проверить соединение»"
      fi
    else
      warn "config.json ещё не создан — задайте язык и почту в Системной консоли после входа."
    fi
  fi

  # ---------- 7. Бэкап ----------
  if [[ $DO_BACKUP == y ]]; then
    step "Ежедневный бэкап"
    local PG_USER PG_DB
    PG_USER=$(get_env POSTGRES_USER); PG_USER=${PG_USER:-mmuser}
    PG_DB=$(get_env POSTGRES_DB);     PG_DB=${PG_DB:-mattermost}
    cat > /usr/local/bin/mattermost-backup <<EOF
#!/usr/bin/env bash
set -euo pipefail
cd "${INSTALL_DIR}"
DIR="${INSTALL_DIR}/backups"
TS=\$(date +%F_%H-%M)
mkdir -p "\$DIR"
docker compose -f docker-compose.yml -f docker-compose.nginx.yml exec -T postgres \\
  pg_dump -U "${PG_USER}" "${PG_DB}" | gzip > "\$DIR/db_\$TS.sql.gz"
tar -czf "\$DIR/files_\$TS.tar.gz" -C volumes/app/mattermost config data
find "\$DIR" -type f -name '*.gz' -mtime +$((BACKUP_KEEP - 1)) -delete
echo "\$(date '+%F %T') бэкап готов: \$TS"
EOF
    chmod +x /usr/local/bin/mattermost-backup
    echo "30 3 * * * root /usr/local/bin/mattermost-backup >> /var/log/mattermost-backup.log 2>&1" \
      > /etc/cron.d/mattermost-backup
    ok "Бэкап каждый день в 03:30 → ${INSTALL_DIR}/backups (хранится ${BACKUP_KEEP} дн.)"
  fi

  # ---------- Итог ----------
  local mins=$(( (SECONDS - START_TS) / 60 ))
  echo
  echo "${C_GREEN}${C_BOLD}╔══════════════════════════════════════════════════════╗"
  echo "║          Mattermost установлен! (${mins} мин)"
  echo "╚══════════════════════════════════════════════════════╝${C_RESET}"
  echo
  echo "  ${C_BOLD}Откройте:${C_RESET}  https://${DOMAIN}"
  echo "  Первый зарегистрированный пользователь станет администратором."
  echo
  echo "  ${C_BOLD}Полезные команды${C_RESET} (из папки ${INSTALL_DIR}):"
  echo "    Логи:         docker compose logs -f"
  echo "    Перезапуск:   docker compose restart"
  echo "    Остановка:    docker compose down"
  [[ $DO_BACKUP == y ]] && echo "    Бэкап сейчас: mattermost-backup"
  echo
  echo "  Пароль базы данных сохранён в ${INSTALL_DIR}/.env"
  echo
  echo "  ${C_DIM}Installer by ${AUTHOR_NAME} · ${AUTHOR_URL}${C_RESET}"
  echo
}

main "$@"
