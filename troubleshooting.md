---
layout: default
title: "Діагностика Smart Place"
permalink: /troubleshooting/
nav_prefix: "../"
---

# Діагностика та типові несправності

{% include nav.md %}

Документ описує **саме наявну робочу версію**, не майбутній SMS-memory fix. При виникненні помилок відключайте відповідний Scheduler і виправляйте причину поетапно; не перевстановлюйте RSC «про всяк випадок».

## 1. Швидкий алгоритм

1. Перевірити LTE та SMS: `/tool sms print`, `/tool sms inbox print detail`.
2. Перевірити RouterOS Scheduler: `/system scheduler print detail where name~"smart-place"`.
3. Перевірити останні записи: `/log print where message~"SmartPlace:"` і `/log print where topics~"script"`.
4. Перевірити JSON і HTTP через `/system script run smart-place-selftest`.
5. Окремо запустити `/system script run smart-place-cron` або `/system script run smart-place-sms-handler`, лише якщо не має бути повторно виконано стару `set`-SMS.
6. Після відновлення — вмикати окремі Scheduler, перевіряти `run-count` та **нові** логи.

### Аварійна зупинка автоматики

```routeros
/system scheduler disable [find name="smart-place-alert-tick"]
/system scheduler disable [find name="smart-place-sms-tick"]
/system script job print detail
```

Вимкнення Scheduler не зупиняє вже розпочатий job. Якщо відповідний job дійсно завис і його потрібно зупинити, спершу перевірте його ідентичність, потім застосовуйте адресне видалення job; це **не** видалення скрипта:

```routeros
/system script job print detail
```

## 2. `Empty device config`

**Симптом:**

```text
SmartPlace: cron failure for flash/smart-place-device-guard.json: Empty device config
```

**Уже виявлена на реальному пристрої причина:** Scheduler міг знайти файл (`count=1`), але при `policy` без `sensitive` отримував `type=nil bytes=0`. Пробний Scheduler із `sensitive` отримав `type=str bytes=185`. Отже, спершу перевірте **дозволи**:

```routeros
/system scheduler print detail where name~"smart-place"
```

Очікується `policy=ftp,read,write,policy,test,sensitive` для обох. Для вже встановленої системи:

```routeros
/system scheduler set [find name="smart-place-alert-tick"] policy=ftp,read,write,policy,test,sensitive
/system scheduler set [find name="smart-place-sms-tick"] policy=ftp,read,write,policy,test,sensitive
```

Після зміни перевірте файл у тому ж контексті, де виникала помилка. Наявність файлу без права прочитати `contents` **не означає**, що JSON порожній на диску. Новий інсталятор вже має правильні Scheduler policy.

## 3. `invalid json` та `ERR: parse failed`

Причини можуть відрізнятися: неправильний файл конфігурації, відсутність дозволів під час автоматичного запуску, BOM/зайві символи, неправильно отриманий JSON від ESP32 чи помилка конкретного етапу. Лог нового Worker/Handler вказує стадію (`config JSON`, `GET JSON`, `SET response JSON`).

```routeros
/file print detail where name="flash/smart-place-device-guard.json"
:local f [/file find where name="flash/smart-place-device-guard.json"]
:local raw [/file get [:pick $f 0] contents]
:put ("bytes=" . [:len $raw])
:put ([:deserialize from=json value=$raw options=json.no-string-conversion]->"ip")
```

Для перевіреної конфігурації очікується IP `192.168.12.254` та розмір близько **185 байтів** (довжина залежить від перенесень рядків). Не замінюйте файл до підтвердження, що **саме його байти** некоректні.

## 4. HTTP GET не працює / немає датчиків

```routeros
/ping 192.168.12.254 count=4
/system script run smart-place-selftest
```

Якщо self-test отримує `code: 200` і перелік сенсорів, REST і парсинг для `guard` справні. Якщо `fetch` помиляється, перевірте IP, живлення ESP32, LAN/VLAN, firewall, HTTP root `/`, розмір відповіді та JSON. Для цього комплекту HTTP запит застосовує **RAM-файл** (`output=file dst-path=...`); на протестованому Chateau `as-value output=user` спричиняв помилку `please use 'output' option`. Не замінюйте перевірений механізм без окремого тесту.

## 5. `MBIM: MEMORY_FULL (6)`

**Статус: відомий невиправлений дефект, відкладений до другого етапу.**

Під час `get guard` модем повернув:

```text
SmartPlace: SMS part 3/4 failed ...: Can't send SMS with MBIM: MEMORY_FULL (6)
SmartPlace: reply not fully delivered
```

Це **не** свідчить про помилку ESP32. Проблема стосується SMS-сховища/поведінки модема. Підозра на накопичення повідомлень у SIM/модемі є обґрунтованою, але на цій установці джерело **ще не підтверджене AT-діагностикою**.

Безпечні діагностичні команди, що **нічого не видаляють**:

```routeros
/tool sms print
/tool sms inbox print detail
/interface lte at-chat lte1 input="AT+CPMS?" wait=yes
```

`AT+CPMS?` залежить від можливостей модема й може бути недоступною через MBIM. Не виконуйте навмання команди масового видалення SMS (`AT+CMGD=1,4` і подібні): вони можуть знищити потрібні вхідні повідомлення. **Стадія 2** — окреме розслідування, рішення, контрольні тести й окремий випуск RSC. До цього моменту аварійні SMS не можна вважати гарантованими.

## 6. Прийшли не всі частини `get guard`

Handler розділяє довгу відповідь на **окремі** SMS (по **64 символи даних** максимум на частину; до **8 частин**), додаючи заголовок `<device> i/n:` та паузу **3 с** між відправленнями. Це **не** справжні concatenated SMS; частини можуть прийти не за порядком або загубитися. Пошукайте:

```routeros
/log print where message~"SmartPlace: SMS part"
/log print where message~"SmartPlace: reply not fully delivered"
```

Повтор `get` — безпечне читання, але після `MBIM: MEMORY_FULL` без відновлення SMS-пам'яті він не вирішує проблему. Автоматичні повторні відправлення навмисно не ввімкнені.

## 7. На `get` прийшов попередній `help`

Можливі дві причини: затримка доставки старої SMS з боку мобільного оператора або повторна обробка повідомлення, яке залишилося в Inbox після невдалого видалення. У поточному Handler є RAM-дедуплікація `spHandledSms` за ID і timestamp, але вона **скидається після reboot або імпорту**.

```routeros
/tool sms inbox print detail
/log print where message~"inbox delete failed"
```

Не видаляйте всі повідомлення; прибирайте лише точно ідентифіковані старі команди, особливо `set`.

## 8. Висить `help guard` / SMS Handler

Обробник SMS ізольовано від cron; `help` більше не запускає фонове REST-опитування. Проте виклик `/tool sms send` може затримуватись через LTE. Потрібно відрізняти **реально активний** job від довгої доставки SMS:

```routeros
/system script job print detail
/tool sms print
/log print where topics~"script"
```

Число `1`, яке друкується під час ручного виклику скрипта, саме по собі **не є** статусом зависання — це може бути результат команди `print count-only` усередині скрипта.

## 9. `cron failure` після встановлення

Спершу звірте **час** повідомлення з останнім імпортом. Старі `cron failure` залишаються в історії журналу; якщо `run-count` зростає й **нових** `script,warning` немає, це позитивний результат. Проте `run-count` означає тільки факт запуску Scheduler, а не гарантований HTTP 200 у кожному циклі: для `guard` частота Scheduler 20 с, а опитування самого пристрою — раз на 60 с.

## 10. Whitelist: нічого не відповідає

```routeros
/file print detail where name="flash/smart-place-trusted-numbers.txt"
:put [/file get [find name="flash/smart-place-trusted-numbers.txt"] contents]
```

Відсутній чи невалідний файл: Handler блокує всю обробку. Порожній — небезпечний режим доступу з будь-якого номера. Якщо скрипт виконується з Scheduler, перевірте `sensitive`. Переконайтеся, що номер у whitelist точно збігається з `phone` із Inbox, включно з кодом країни.

## 11. Службові SMS, `Kyivstar`, `????`

Сучасний Handler не відповідає алфавітним відправникам й ігнорує команди, що не починаються з допустимого `get`, `set`, `help`. Для кирилиці можливі обмеження кодування SMS і відображення `????`. Це не означає, що можна безпечно ігнорувати всі системні повідомлення оператора: перевіряйте Inbox вручну та робіть адресне видалення.

## 12. Постійні проблеми після імпорту

Перевірте, що імпорт створив **три скрипти** (`smart-place-selftest`, `smart-place-sms-handler`, `smart-place-cron`) і **два Scheduler** (`smart-place-sms-tick`, `smart-place-alert-tick`), а старих Worker/Scheduler немає. Інсталятор не змінює `guard.json` та trusted numbers, зате **скидає RAM-стан**, зокрема дедуплікацію й чергу. Імпорт не є засобом очищення SMS-пам'яті.

**Далі:** [Встановлення](../installation/) · [Операційне обслуговування](../operations/) · [Другий етап — окремо](#mbim-memory_full-6).
