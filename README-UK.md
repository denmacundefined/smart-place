# Smart Place — інсталяція, налаштування та тестування

**Оновлено: 15 листопада 2026. Ціль:** MikroTik Chateau, RouterOS 7.24.6, LTE `lte1`, пристрій `guard` за адресою `192.168.12.254`.

## Ключове виправлення цієї збірки

Тест на реальному маршрутизаторі встановив, що завдання RouterOS Scheduler без дозволу `sensitive` **знаходило** `flash/smart-place-device-guard.json`, але `/file get ... contents` повертало `nil`:

```text
SmartPlace probe: count=1 type=nil bytes=0
SmartPlace probe-loop: type=nil bytes=0
```

Після додавання `sensitive` той самий тест зі Scheduler показав:

```text
SP-PROBE bytes=185 type=str
```

Тому **інсталятор тепер створює ОБИДВА Scheduler** (`smart-place-sms-tick` і `smart-place-alert-tick`) із політикою `ftp,read,write,test,policy,sensitive`. Обидва залишаються **вимкненими** після імпорту. Не потрібно змінювати JSON, ESP32 або перепрошивати пристрій. Ручний self-test сам по собі не перевіряє дозволи Scheduler; саме окремий пробний запуск виявив проблему.

**Залишена проблема:** в журналі вже була помилка `Can't send SMS with MBIM: MEMORY_FULL (6)` під час частини `3/4` GET. Це окрема проблема SMS-модема/сховища, **не виправлена** цим інсталятором. Аварійні SMS не можна вважати надійним каналом, поки не усунуто проблему з доставкою.

## Склад і поведінка

| Об'єкт | Роль |
|---|---|
| `smart-place-selftest` | Перевірка читання JSON, GET до `guard`, вивід полів; **не** надсилає SMS і **не** виконує POST |
| `smart-place-sms-handler` | Вхідні `help`, `get`, `set` і відправка SMS; розсилання алертів із RAM-черги |
| `smart-place-cron` | Опитування JSON-пристроїв і формування алертів у RAM-черзі; **не надсилає SMS сам** |
| `smart-place-sms-tick` | Планувальник SMS Handler, кожні 20 с, `sensitive`, початково `disabled=yes` |
| `smart-place-alert-tick` | Планувальник cron, кожні 20 с, `sensitive`, початково `disabled=yes` |

Пристрій описується конфігом `flash/smart-place-device-<name>.json`. Наприклад, `guard`: `name=guard`, `ip=192.168.12.254`, `alert=true`, `interval=60`, `get=flat`, `set=auto`, `wrap=""`. `alert=true` у конфігу дозволяє опитування; фактичну тривогу визначає поле `alert` в HTTP JSON-відповіді.

Довірені номери — `flash/smart-place-trusted-numbers.txt`, один міжнародний номер `+...` на рядок. **Порожній файл дозволяє будь-якому валідному міжнародному номеру надсилати GET/SET/HELP і не дає отримувачів автоматичних алертів**. Для реле це небезпечно: перед постійним використанням заповніть whitelist. Відсутній або некоректний файл блокує доступ (fail closed). Інсталятор **не змінює** обидва типи файлів у `flash/`.

SMS Handler і cron — незалежні. Cron лише ставить тривоги в RAM-чергу; Handler відправляє їх усім довіреним номерам. Між частинами довгої відповіді Handler робить паузу 3 секунди. Немає автоматичного повтору `set` і SMS, бо помилка підтвердження не завжди доводить, що повідомлення не було передано.

## Етап 0. Безпечна підготовка

1. Збережіть копії конфігурацій `flash/smart-place-device-*.json` і `flash/smart-place-trusted-numbers.txt` у себе локально. **Не замінюйте їх файлами-прикладами з ZIP**.
2. Відкрийте WinBox → Terminal і вимкніть обидва планувальники та старий Worker:

```routeros
/system scheduler disable [find name="smart-place-alert-tick"]
/system scheduler disable [find name="smart-place-sms-tick"]
/system scheduler disable [find name="smart-place-tick"]
/system script job print detail
```

3. Перегляньте ` /tool sms inbox print detail ` і вручну приберіть **лише завідомо вже виконані** SMS-команди, особливо `set`. Інсталятор скидає RAM-стан `spHandledSms`, тому стара невидалена `set` може бути виконана ще раз після імпорту. Якщо не впевнені, **не імпортуйте, поки не звірили Inbox**.
4. Якщо скрипт Smart Place ще працює, дочекайтеся завершення або зупиніть **саме його** job перед імпортом. Інсталятор перевіряє запущені роботи й не повинен видаляти активні скрипти.

## Етап 1. Завантаження та повторне встановлення

1. Через WinBox → Files завантажте з пакета **тільки `smart-place-install.rsc`** у корінь Files (не у `flash/`) і замініть попередній файл з такою назвою.
2. Перевірте синтаксис:

```routeros
/import file-name=smart-place-install.rsc verbose=yes dry-run
```

3. Якщо помилок немає, встановіть:

```routeros
/import file-name=smart-place-install.rsc
```

4. Перевірте, що є три скрипти, два нових Scheduler; у кожного Scheduler `disabled=yes` і `policy` містить `sensitive`:

```routeros
/system script print where name~"smart-place"
/system scheduler print detail where name~"smart-place"
```

Інсталятор ідемпотентний: замінює власні старі скрипти/Scheduler, чистить відомі старі назви (`smart-place-tick`, `smart-place-worker` та ін.), залишає конфіги/whitelist незмінними, скидає RAM-стан. **Будь-який повторний імпорт вимкне обидва Scheduler.**

## Етап 2. Перевірка ESP32 та JSON вручну

```routeros
/system script run smart-place-selftest
```

Очікуваний зміст виводу:

```text
Worker config loader: OK (... bytes)
Cron config loader: OK (... bytes)
name=guard ip=192.168.12.254
HTTP transport: RAM file ...
status: finished
code: 200
... показники датчиків ...
alert = false
Self-test finished
```

Текст `Worker config loader` — історична назва діагностичного рядка; зараз працює `smart-place-sms-handler`. Показники датчиків і точна кількість байтів можуть відрізнятися. Self-test **не виконує POST і не надсилає SMS**.

## Етап 3. Ручний тест SMS Handler

1. Надішліть із довіреного номера `help guard` на LTE SIM MikroTik.
2. У терміналі:

```routeros
/system script run smart-place-sms-handler
/system script job print detail
```

Очікується SMS-відповідь і відсутність завислого `smart-place-sms-handler` у jobs. Число `1` на екрані після запуску може бути виводом внутрішнього `print count-only`, а не кодом помилки.

3. Надішліть `get guard`; знову запустіть Handler вручну. При поточному JSON відповідь зазвичай складається з **чотирьох окремих SMS**, але фактична кількість залежить від розміру даних.
4. Перевірте свіжі помилки SMS:

```routeros
/log print where message~"SmartPlace: SMS part"
/log print where message~"SmartPlace: reply not fully delivered"
/tool sms inbox print detail
```

Якщо з'явиться `MBIM: MEMORY_FULL (6)`, **не повторюйте безкінечно `get`** і не покладайтеся на доставку. Причину у пам'яті SIM/модема відкладено для окремої діагностики. Службові відправники (напр. `Kyivstar`) та некоректні команди не повинні отримувати відповіді. Під час переповнення SIM повідомлення можуть залишатися в Inbox.

5. `set guard [0,0,0,0,0]` перевіряйте лише коли зміна реле безпечна. При втраті відповіді **не повторюйте POST навмання**: спочатку зчитайте фактичний стан.

## Етап 4. Ручний тест cron

Залиште планувальники вимкненими. Запустіть:

```routeros
/system script run smart-place-cron
/log print where message~"SmartPlace: cron failure"
```

Під час успішного ручного запуску `cron` виконує HTTP GET, але не надсилає SMS. Якщо фактична відповідь ESP32 містить `alert=false`, повідомлення про тривогу не формується.

## Етап 5. Автоматичний cron через Scheduler

**Вмикайте спочатку тільки cron:**

```routeros
/system scheduler enable [find name="smart-place-alert-tick"]
/system scheduler print detail where name="smart-place-alert-tick"
```

Через кілька запусків `run-count` має збільшитися. Порівняйте часові мітки: у журналі можуть залишатися **старі** `Empty device config`; після виправлення дозволів **нових** таких записів не повинно бути.

```routeros
/log print where message~"SmartPlace: cron failure"
```

`interval=20s` у Scheduler — частота перевірки конфігів; `interval=60` у JSON пристрою — фактичний інтервал його GET-опитування. **Успішний cron не зобов'язаний щось писати в лог**.

Якщо знову є `Empty device config`, негайно вимкніть `smart-place-alert-tick` і перевірте `policy` Scheduler на `sensitive`. На реальному Chateau саме відсутність цієї політики призводила до `type=nil bytes=0`.

## Етап 6. Автоматична обробка SMS (опційно до усунення MEMORY_FULL)

Спершу заповніть whitelist (інакше дозволений будь-який валідний міжнародний номер). Якщо готові до обмеженого тестування попри проблему модема:

```routeros
/system scheduler enable [find name="smart-place-sms-tick"]
/system scheduler print detail where name="smart-place-sms-tick"
```

Надішліть **нову** `help guard`, нічого не запускайте вручну. Перевірте відповідь, `run-count`, jobs і журнал:

```routeros
/system script job print detail
/log print where message~"SmartPlace:"
```

Алерт від `cron` потрапляє в RAM-чергу та відправляється SMS Handler на наступному циклі. Якщо отримання SMS ненадійне, не використовуйте це як єдиний канал критичної охоронної сигналізації. Тест переходу `alert=false → true → false` ще потрібно виконати окремо, не створюючи небажаних фізичних подій.

## Етап 7. Зупинка або відкат дозволів без повторного імпорту

Зупинити обидва автоматичні процеси:

```routeros
/system scheduler disable [find name="smart-place-alert-tick"]
/system scheduler disable [find name="smart-place-sms-tick"]
```

Якщо потрібно виправити **лише дозволи** на вже встановленому комплекті **без імпорту і без скидання RAM-стану**:

```routeros
/system scheduler set [find name="smart-place-alert-tick"] policy=ftp,read,write,test,policy,sensitive
/system scheduler set [find name="smart-place-sms-tick"] policy=ftp,read,write,test,policy,sensitive
```

Імпортуйте пакет, коли потрібен відтворюваний стан скриптів на майбутнє. Тимчасові пробні Scheduler `smart-place-file-probe` можна видалити **лише якщо вони справді існують**:

```routeros
/system scheduler remove [find name="smart-place-file-probe"]
```

## Обмеження й застереження

- Дані `flash/` переживають перезавантаження, але RAM-черга алертів, `spPriorAlert`, `spLastCheck`, `spHandledSms` — ні. Після перезавантаження або імпорту можливі повторні реакції на старі SMS (якщо вони залишилися в Inbox) і повторний алерт, якщо стан уже тривожний.
- Під час обробки кількох SMS є пауза 3 секунди; модем усе одно може відхилити частину з `MEMORY_FULL`. Втрата частини GET відрізняється від помилки REST-запиту.
- Для алертів немає підтвердження фактичної доставки, постійної черги чи гарантованого exactly-once. Інсталятор не є сертифікованою охоронною системою.
- Файли тимчасових HTTP-відповідей створюються в RAM-корені Files (`smart-place-*-http.txt`), а не у `flash/`. При помилках перевіряйте тимчасові залишки, не видаляючи довільні файли.
- Невідомі й службові SMS залишаються в Inbox для ручного перегляду. Регулярно переглядайте Inbox: його заповнення може впливати на роботу модема.
- У ZIP `smart-place-device-guard.json` і `smart-place-trusted-numbers.txt` — **тільки зразки**. Не завантажуйте їх поверх робочих файлів на маршрутизаторі.

Довідка MikroTik: [Scheduler](https://manual.mikrotik.com/docs/system-information-and-utilities/scheduler/), [Scripting](https://manual.mikrotik.com/docs/developer-guides/scripting/), [SMS](https://manual.mikrotik.com/docs/mobile-networking/sms/).
