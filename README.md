# README: Использование плагина dns_acmeproxy (NetAngels) вместо AcmeProxy в acme.sh

Этот плагин сохраняет имена функций dns_acmeproxy_add/dns_acmeproxy_rm (как в штатном dns_acmeproxy), но работает
напрямую с API NetAngels:

- ACMEPROXY_PASSWORD — это API-ключ, по которому генерируется Bearer-токен
- ACMEPROXY_USERNAME — это ID DNS-зоны в NetAngels
- ACMEPROXY_ENDPOINT не используется

Поддерживается acme.sh. Плагин добавляет и удаляет TXT-записи для валидации DNS-01.

## Требования

- Установленный acme.sh (https://github.com/acmesh-official/acme.sh)
- API-ключ NetAngels (для получения Bearer токена)
- ID вашей DNS-зоны в NetAngels

## Скачивание в корень проекта

Замените плейсхолдеры на ваш репозиторий/ветку/путь:

```sh
# В корне вашего проекта
curl -fsSL https://raw.githubusercontent.com/maintainer64/netangels-dns-acme/main/dns_acmeproxy.sh -o ./dns_acmeproxy.sh
chmod +x ./dns_acmeproxy.sh
```

Либо через git:

```sh
git clone https://github.com/maintainer64/netangels-dns-acme.git
cp netangels-dns-acme/dns_acmeproxy.sh ./dns_acmeproxy.sh
chmod +x ./dns_acmeproxy.sh
```

## Установка вместо штатного dns_acmeproxy

acme.sh ищет плагины в каталоге ~/.acme.sh/dnsapi/. Чтобы подменить штатный dns_acmeproxy:

```sh
# Резервная копия штатного плагина (если он есть)
mkdir -p ~/.acme.sh/dnsapi
if [ -f ~/.acme.sh/dnsapi/dns_acmeproxy.sh ]; then
  cp ~/.acme.sh/dnsapi/dns_acmeproxy.sh ~/.acme.sh/dnsapi/dns_acmeproxy.sh.bak
fi

# Установка нашего плагина
cp ./dns_acmeproxy.sh ~/.acme.sh/dnsapi/dns_acmeproxy.sh
chmod +x ~/.acme.sh/dnsapi/dns_acmeproxy.sh
```

Для proxmox 9 (debian 13)

```sh
mkdir -p /usr/share/proxmox-acme/dnsapi
if [ -f /usr/share/proxmox-acme/dnsapi/dns_acmeproxy.sh ]; then
  cp /usr/share/proxmox-acme/dnsapi/dns_acmeproxy.sh /usr/share/proxmox-acme/dnsapi/dns_acmeproxy.sh.bak
fi

# Установка нашего плагина
cp ./dns_acmeproxy.sh /usr/share/proxmox-acme/dnsapi/dns_acmeproxy.sh
chmod +x /usr/share/proxmox-acme/dnsapi/dns_acmeproxy.sh
```
Важно:

- При обновлении acme.sh плагин может быть перезаписан. Чтобы отключить автообновление:
  ```sh
  acme.sh --upgrade 0
  ```
  Или просто повторно копируйте файл после апгрейда.

## Настройка переменных окружения

Укажите зону и API-ключ NetAngels:

```sh
export ACMEPROXY_USERNAME="ZONE_ID"      # ID вашей DNS-зоны NetAngels
export ACMEPROXY_PASSWORD="API_KEY"      # API-ключ для генерации Bearer-токена
```

Подсказки:

- ZONE_ID можно взять в панели/через API NetAngels (это тот же идентификатор, что в URL списков
  /dns/zones/{ZONE_ID}/records/).
- ACMEPROXY_ENDPOINT не используется.

## Выпуск сертификата

Пример для домена и wildcard:

```sh
acme.sh --issue --dns dns_acmeproxy -d example.com -d *.example.com
```

Установка сертификата (пример):

```sh
acme.sh --install-cert -d example.com \
  --key-file       /etc/ssl/private/example.com.key \
  --fullchain-file /etc/ssl/certs/example.com.fullchain.pem \
  --reloadcmd     "systemctl reload nginx"
```

## Как это работает

- Плагин получает Bearer-токен по API-ключу:
  POST https://panel.netangels.ru/api/gateway/token/ (Content-Type: application/x-www-form-urlencoded, тело: api_key=<
  API_KEY>)
- Создает TXT-запись:
  POST https://api-ms.netangels.ru/api/v1/dns/records/
  Тело: {"name": "<FQDN>", "type": "TXT", "value": "<TXT_VALUE>"}
- Удаляет TXT-запись:
    - Сначала пробует удалить по сохраненному id
    - Если id не найден — листает список записей зоны и удаляет подходящие по name+value:
      GET https://api-ms.netangels.ru/api/v1/dns/zones/{ZONE_ID}/records/
      DELETE https://api-ms.netangels.ru/api/v1/dns/records/{id}/

## Проверка доступа к API вручную

1) Получить токен:

```sh
curl -fsSL 'https://panel.netangels.ru/api/gateway/token/' \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  --data-urlencode "api_key=$ACMEPROXY_PASSWORD"
```

2) Список записей зоны:

```sh
TOKEN="Bearer <скопируйте_из_ответа>"
curl -fsSL "https://api-ms.netangels.ru/api/v1/dns/zones/${ACMEPROXY_USERNAME}/records/" \
  -H "Authorization: $TOKEN"
```

## Отладка

- Включите подробный лог:
  ```sh
  export DEBUG=2
  export LOG_FILE="$HOME/acme_netangels.log"
  ```
- Повторите выпуск:
  ```sh
  acme.sh --issue --dns dns_acmeproxy -d example.com
  ```

## Откат к штатному плагину

```sh
if [ -f ~/.acme.sh/dnsapi/dns_acmeproxy.sh.bak ]; then
  mv ~/.acme.sh/dnsapi/dns_acmeproxy.sh.bak ~/.acme.sh/dnsapi/dns_acmeproxy.sh
fi
```

## Примечания

- Плагин сам убирает завершающую точку у FQDN (если вдруг попала).
- TTL не задается (используются значения по умолчанию NetAngels). При необходимости можно расширить плагин.
- Для production лучше отключить автообновление acme.sh или следить, чтобы плагин не перезаписывался при апгрейде.