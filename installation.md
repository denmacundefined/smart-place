---
layout: default
title: "3. Встановлення на чистий MikroTik LTE"
permalink: /installation/
nav_prefix: "../"
---

# 3. Встановлення на чистий MikroTik із LTE — від А до Я

{% include nav.md %}

**Мета:** із чистого або раніше не налаштованого RouterOS отримати стабільно запущені SMS-команди `help/get/set` і фонове опитування `guard`. Усі дії поділено на етапи: **не активуйте автоматику до успішного ручного тесту**.

**Опрацьована платформа:** MikroTik Chateau / RouterOS **7.24.6** / LTE **`lte1`** / ESP32 **`192.168.12.254`** / SMS-порт `lte1`. На інших моделях назви інтерфейсів, підтримка SMS, схема дисків і синтаксис окремих команд можуть відрізнятися: спочатку перевірте сумісність.

## 3.1. Карта встановлення

| Етап | Що робимо | Критерій готовності |
|---|---|---|
| 0 | Резервна копія RouterOS та підготовка обладнання | Маємо доступ через WinBox/SSH і план відновлення |
| 1 | SIM, LTE, перевірка SMS | Модем видимий; `/tool sms` показує `status: running` |
| 2 | Локальна мережа до ESP32 | `ping` і HTTP GET проходять |
| 3 | `flash/` та JSON-файли | Один коректний `guard.json` + **непорожній** whitelist |
| 4 | Завантаження RSC і синтаксична перевірка | `/import ... dry-run` без помилок |
| 5 | Імпорт | 3 скрипти, 2 вимкнені Scheduler |
| 6 | Self-test / ручний SMS / cron | HTTP 200; `help/get` відпрацьовують |
| 7 | Cron Scheduler | Лічильник росте, нових warnings немає |
| 8 | SMS Scheduler | `help guard` відпрацьовує без ручного запуску |
| 9 | Функціональний тест тривоги | Реальний перехід `false→true→false`, SMS приходять |
| 10 | Захист і обслуговування | Whitelist, бекап, нагляд за модемом |

## 3.2. Етап 0 — підготовка та безпека

1. Забезпечте **живлення** MikroTik і ESP32, SIM з послугою SMS та доступ до локальної мережі.
2. Підключіться через WinBox або SSH **із власної довіреної мережі**. Не відкривайте WinBox/SSH у загальний інтернет.
3. Переконайтеся, що ви маєте адміністративні права; Smart Place потребує `ftp,read,write,test,policy`, а його **Scheduler** додатково `sensitive`.
4. Збережіть резервну конфігурацію маршрутизатора згідно з правилами вашої мережі. Для чистого тестового пристрою можна додатково виконати:

   ```routeros
   /system backup save name=before-smart-place
   /export file=before-smart-place-export
   ```

   Резервна копія може містити секрети. Скопіюйте її у захищене місце, **не завантажуйте в публічний GitHub**; не залишайте великі резервні файли на роутері з мінімальною вільною flash-пам'яттю.

5. **Не запускайте `/system reset-configuration`** лише заради Smart Place. Встановлення не потребує скидання роутера до заводського стану.

## 3.3. Етап 1 — налаштування SIM і LTE

### 3.3.1. Підключення модема

Установіть активну SIM у маршрутизатор (живлення/встановлення SIM — згідно з інструкцією конкретної моделі). Перевірте, як називається LTE-інтерфейс:

```routeros
/interface lte print detail
/interface lte monitor lte1 once
```

На перевіреному Chateau модем — `lte1`. Якщо у вас інший інтерфейс, **перед імпортом адаптуйте значення** `smsPort "lte1"` у RSC; не міняйте вхідні параметри довільно. APN за потреби налаштовується в конфігурації LTE оператора — Smart Place сам APN не змінює:

```routeros
/interface lte apn print
```

Для локального REST-запиту доступ до інтернету через LTE **не обов'язковий**: MikroTik і ESP32 повинні мати локальну IP-зв'язність. Але SIM має працювати в мобільній мережі для надсилання й приймання SMS.

### 3.3.2. Увімкніть приймання SMS

```routeros
/tool sms set port=lte1 receive-enabled=yes
/tool sms print
```

На протестованому пристрої `status: running`, `receive-enabled: yes`, `port: lte1`. Якщо ні, перевірте SIM, модем, налаштування SMS і підтримку конкретної моделі. У деяких конфігураціях може бути корисним `polling=yes` (RouterOS v7.16+), але **вмикайте лише якщо необхідно** й підтримує ваш модем.

> Smart Place читає звичайні текстові повідомлення з `/tool sms inbox`. Не потрібно надсилати вбудовану RouterOS-команду `:cmd ...`, а також не потрібно вмикати дистанційне виконання адміністративних скриптів через SMS.

### 3.3.3. Тест приймання й відправлення

Надішліть **звичайну SMS** з власного телефона на номер SIM у MikroTik, наприклад `test`, потім:

```routeros
/tool sms inbox print detail
```

Повідомлення має бути у Inbox (надалі Smart Place його не оброблятиме, бо це не підтримувана команда). Для тесту вихідної SMS можете використати **свій номер**, підставивши його замість шаблону:

```routeros
/tool sms send port=lte1 phone-number="+380XXXXXXXXX" message="SP modem test" status-report-request=no
```

Шаблон `+380XXXXXXXXX` **потрібно замінити**, його не слід надсилати буквально. Кожна SMS може тарифікуватися. Якщо модем повертає `MBIM: MEMORY_FULL`, діагностику пам'яті залишаємо на **окремий етап** — тут нічого не чистимо навмання.

## 3.4. Етап 2 — мережа до ESP32

ESP32 із REST-інтерфейсом повинен бути доступний маршрутизатору по IP. Для `guard`:

```routeros
/ping 192.168.12.254 count=4
/ip address print
/ip route print
```

Якщо ESP32 у іншому VLAN/підмережі, налаштуйте маршрути та правила firewall відповідно до вашої мережі. **Не переналаштовуйте bridge/LAN наосліп**: на реальному маршрутизаторі це може від'єднати WinBox, DHCP та інші пристрої. Адреса `192.168.12.254` — фактична IP-адреса тестового `guard`, а не IP за замовчуванням будь-якого MikroTik.

Опціонально перевірте HTTP до ESP32 без відправлення SMS:

```routeros
/tool fetch url="http://192.168.12.254/" http-method=get output=file dst-path=sp-install-probe.txt
/file print where name="sp-install-probe.txt"
```

Після перевірки **приберіть лише тестовий RAM-файл**:

```routeros
/file remove [find name="sp-install-probe.txt"]
```

Якщо GET повертає не JSON або HTTP-помилку, спочатку виправте ESP32/мережу. **Інсталятор не створює REST API на пристрої.**

## 3.5. Етап 3 — підготовка файлів `flash/`

### 3.5.1. Перевірте постійний диск

```routeros
/file print
/system resource print
```

На перевіреному Chateau папка `flash/` була доступна, а вільного місця у внутрішньому сховищі було дуже мало. Зберігайте там **лише малі постійні конфіги**, а результати `fetch` не переносьте з RAM до `flash/`.

Якщо `flash/` **відсутня**, ця збірка **не підтримує автоматично іншу схему зберігання**: потрібно адаптувати шляхи `flash/...` у скриптах і перевірити поведінку при перезавантаженні. Для документованого встановлення потрібна справжня папка `flash/`.

### 3.5.2. Файл пристрою `guard`

У текстовому редакторі на комп'ютері створіть **UTF-8 без BOM** файл `smart-place-device-guard.json`:

```json
{
  "name": "guard",
  "ip": "192.168.12.254",
  "alert": true,
  "interval": 60,
  "help": "Guard: get guard | set guard [1,0,0,1,0]",
  "get": "flat",
  "set": "auto",
  "wrap": ""
}
```

Той самий файл як шаблон: [завантажити `guard.json`](../downloads/smart-place-device-guard.example.json). За допомогою WinBox → **Files** завантажте файл **всередину `flash/`**, не в корінь. Назва у `flash/` має бути **точно** `smart-place-device-guard.json`.

Перевірте:

```routeros
/file print detail where name="flash/smart-place-device-guard.json"
:put [/file get [find name="flash/smart-place-device-guard.json"] contents]
```

Має виводитися текст JSON; у файлі не повинно бути `//`-коментарів, випадкових символів чи невидимих префіксів.

### 3.5.3. Файл довірених телефонів

Створіть файл **з точною назвою** `smart-place-trusted-numbers.txt`, помістіть його в `flash/`. Вміст (це **приклад із плейсхолдерами**, замініть на свої номери):

```text
+380XXXXXXXXX
+372XXXXXXXX
```

Один номер у міжнародному форматі `+` і **лише цифри** на рядок. Без лапок, пробілів, коментарів і заголовків. Рекомендовано UTF-8 без BOM, без порожніх рядків усередині; звичайний кінцевий перевід рядка допустимий. **Не публікуйте цей реальний файл на GitHub.**

Перевірте:

```routeros
/file print detail where name="flash/smart-place-trusted-numbers.txt"
:put [/file get [find name="flash/smart-place-trusted-numbers.txt"] contents]
```

**Критично.** У поточній реалізації **порожній** файл означає *публічний режим*: будь-який валідний міжнародний номер може надсилати `get`, `set` та `help`; автоматичні алерти не мають одержувачів. Відсутній або неправильно заповнений файл викликає блокування команд (`DENY ALL`). Для реальної експлуатації whitelist має бути **непорожнім і валідним**.

## 3.6. Етап 4 — завантажте RSC та перевірте синтаксис

[Завантажити останній зафіксований інсталятор](../downloads/smart-place-install.rsc). Через WinBox → Files покладіть `smart-place-install.rsc` **у корінь Files**, не у `flash/`:

```text
Files/
├── smart-place-install.rsc       # інсталятор (корінь)
└── flash/
    ├── smart-place-device-guard.json
    └── smart-place-trusted-numbers.txt
```

У терміналі:

```routeros
/import file-name=smart-place-install.rsc verbose=yes dry-run
```

Упевніться, що немає помилок синтаксису/політик. Якщо встановлюєте поверх старої версії, **спочатку** вимкніть Scheduler і перевірте Inbox на старі `set`-команди. Повторний імпорт скидає RAM-ознаки оброблених SMS, тому невидалений `set` може виконатися ще раз. Див. [експлуатацію](../operations/).

## 3.7. Етап 5 — імпорт інсталятора

```routeros
/import file-name=smart-place-install.rsc
```

Після успішного імпорту мають існувати **три скрипти** і **два Scheduler**:

```routeros
/system script print where name~"smart-place"
/system scheduler print detail where name~"smart-place"
```

Скрипти: `smart-place-selftest`, `smart-place-sms-handler`, `smart-place-cron`. Scheduler: `smart-place-sms-tick` і `smart-place-alert-tick`.

В обох Scheduler має бути `disabled=yes` і політика:

```text
ftp,read,write,policy,test,sensitive
```

Цей `sensitive` **обов'язковий** у підтвердженій конфігурації: без нього Scheduler знаходив файл у `flash/`, але отримував `type=nil bytes=0` при читанні `contents`. Проєкт навмисно **не запускає автоматику одразу після імпорту**.

## 3.8. Етап 6 — self-test і ручні функції

### JSON + HTTP GET без зміни стану

```routeros
/system script run smart-place-selftest
```

Перевірте рядки:

```text
Worker config loader: OK (... bytes)
Cron config loader: OK (... bytes)
name=guard ip=192.168.12.254
HTTP transport: RAM file (output=file, no as-value, no keep-result)
status: finished
code: 200
... перелік показників ...
Self-test finished
```

Назва `Worker config loader` у self-test історична; окремий старий `smart-place-worker` більше не використовується. Self-test **не надсилає SMS і не виконує POST**. Він перевіряє `guard`, а не кожен доданий у майбутньому пристрій.

### Ручний тест SMS-команди

Надішліть SMS **з номера, внесеного до whitelist**:

```text
help guard
```

Потім вручну запустіть Handler:

```routeros
/system script run smart-place-sms-handler
/system script job print detail
```

Очікується SMS-відповідь із вмісту `help` і відсутність завислого Handler. Якщо після виконання в терміналі з'являється `1`, це може бути результатом службового `print count-only`, а не код помилки.

Наступним тестом надішліть `get guard` і повторіть ручний запуск Handler. Очікується одна або кілька SMS з показниками (для перевіреного прикладу зазвичай **4 частини**, але довжина відповіді динамічна). Перевірте журнал, особливо `SMS part ... failed`.

### Ручний тест cron

```routeros
/system script run smart-place-cron
/log print where message~"SmartPlace: cron failure"
```

Cron повинен виконатися без свіжих помилок. При `alert=false` автоматична тривога не формується. Під час **ручного** запуску `cron` SMS не надсилає.

### SET — лише після перевірки безпеки реле

```text
set guard [0,0,0,0,0]
```

Це справжній **HTTP POST**, який може перемкнути виконавчі пристрої. Не перевіряйте його на небезпечному навантаженні. Якщо відповідь SMS загубилася, **не повторюйте команду без перевірки фактичного стану**.

## 3.9. Етап 7 — ввімкніть автоматичний cron

```routeros
/system scheduler enable [find name="smart-place-alert-tick"]
/system scheduler print detail where name="smart-place-alert-tick"
```

Очікується зростання `run-count` кожні 20 с. `interval=60` у JSON пристрою регулює частоту **HTTP GET**, а не частоту запуску Scheduler. Перегляньте **нові** помилки:

```routeros
/log print where message~"SmartPlace: cron failure"
/log print where topics~"script,warning"
```

Якщо нових `Empty device config` немає, це позитивна ознака. Для `guard` було підтверджено зміну `run-count` з 5 до 8 без нових warnings після додавання `sensitive`.

## 3.10. Етап 8 — автоматизуйте SMS-команди

Після перевірки whitelist і ручного Handler:

```routeros
/system scheduler enable [find name="smart-place-sms-tick"]
/system scheduler print detail where name="smart-place-sms-tick"
```

Надішліть **нову** SMS `help guard` і **не запускайте Handler вручну**. Відповідь має прийти автоматично. Після цього перевірте `get guard`; при довгій відповіді уважно перевірте всі частини.

> **Увага:** на тестовому обладнанні раніше виникала `MBIM: MEMORY_FULL (6)`. Навіть якщо конкретна SMS надійшла, доставка тривог не є гарантованою. Не використовуйте SMS як єдину систему захисту життя/майна.

## 3.11. Етап 9 — перевірка тривоги

Переконайтеся, що `"alert": true` у конфігурації **дозволяє опитування**, а **фактична GET-відповідь ESP32** може переходити `false→true→false`.

Безпечніший тест — програмна імітація на стороні ESP32, **без випускання газу**. Під час тесту переконайтеся, що при першому `true` прийшло SMS, при тривалому `true` немає повтора, після `false` стан скинуто. Реальний газовий тест на цій інсталяції вже був проведений користувачем: доставлено **4/4 SMS**, а скидання до `false` підтверджене. Але систематична повторна тривога після скидання й гарантії доставки ще не перевірені.

## 3.12. Етап 10 — завершення та приймання

Перевірте кінцевий стан:

```routeros
/tool sms print
/system script print where name~"smart-place"
/system scheduler print detail where name~"smart-place"
/system script job print detail
/log print where message~"SmartPlace:"
```

Контрольний список:

- [ ] LTE-модем у мережі, SMS працюють.
- [ ] ESP32 доступний за IP, GET повертає HTTP 200.
- [ ] У `flash/` є валідний JSON пристрою й **непорожній** whitelist.
- [ ] Рівно 3 актуальні скрипти та 2 Scheduler Smart Place.
- [ ] У **обох** Scheduler є `sensitive`; `run-count` зростає.
- [ ] Self-test без помилок; `help/get` приймаються тільки з довірених номерів.
- [ ] Немає нових `cron failure` / `Empty device config`.
- [ ] Відомий ризик `MEMORY_FULL` прийнятий як **незакритий**, алерти не вважаються гарантованими.
- [ ] Є локальні резервні копії та записана робоча версія RSC.

## 3.13. Якщо щось пішло не так

**Швидко зупинити обидва цикли без видалення файлів:**

```routeros
/system scheduler disable [find name="smart-place-alert-tick"]
/system scheduler disable [find name="smart-place-sms-tick"]
```

**Перевірити активні jobs:**

```routeros
/system script job print detail
```

**Не очищайте весь SMS Inbox автоматично** і не скидайте модем, доки не зрозумієте, які повідомлення в ньому зберігаються. Подальші інструкції — [Діагностика](../troubleshooting/) та [Операції/оновлення](../operations/).

---

[Далі: 4. Як користуватися](../usage/)
