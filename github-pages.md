---
layout: default
title: "Як опублікувати Smart Place на GitHub Pages"
permalink: /github-pages/
nav_prefix: "../"
---

# GitHub Pages: публікація документації з темою Architect

{% include nav.md %}

Цей архів — **вже готовий Jekyll-сайт**. Його можна розпакувати в корінь GitHub-репозиторію. Вибрана офіційна тема GitHub Pages **Architect v0.2.0**.

## 1. Що всередині ZIP

```text
_config.yml                  # Jekyll / remote_theme
index.md                     # Головна
README.md                    # Інструкція для репозиторію
_includes/nav.md             # Єдине меню сторінок
assets/architecture.svg      # Готова SVG-діаграма для браузера
diagrams/*.mmd               # Вихідні Mermaid-схеми
diagrams/components.puml      # UML / PlantUML-джерело
overview.md                   # Розділ 1
architecture.md               # Розділ 2
installation.md               # Розділ 3
usage.md                      # Розділ 4
configuration.md              # Довідник REST і JSON
security.md                   # Безпека
troubleshooting.md            # Діагностика
operations.md                 # Експлуатація
developer.md                  # Для розробників
github-pages.md               # Ця інструкція
downloads/                   # Зафіксований робочий RSC та приклади
```

## 2. Тема Architect — точна конфігурація

В `_config.yml` є:

```yaml
remote_theme: pages-themes/architect@v0.2.0
plugins:
  - jekyll-remote-theme
```

Це синтаксис, рекомендований авторами теми [pages-themes/architect](https://github.com/pages-themes/architect). **Не використовуйте `.nojekyll`**: тоді Markdown не проходитиме Jekyll-збірку, а `remote_theme` не застосовується.

Додаткові змінні: `title`, `description`, `lang`, `show_downloads`, `baseurl`, `url`. Усі сторінки використовують `layout: default` та окремий `permalink`, тож навігація має зручні адреси `/overview/`, `/architecture/`, тощо.

## 3. Створіть репозиторій на GitHub

1. Відкрийте [GitHub](https://github.com) і створіть репозиторій, наприклад `smart-place-docs`.
2. Розпакуйте ZIP і завантажте **весь вміст папки** `smart-place-github-pages` у корінь репозиторію — не додаткову вкладену папку. `_config.yml` і `index.md` мають опинитися на верхньому рівні.
3. Перевірте, що в `downloads/` лежить лише шаблон конфігурації та RSC, **немає реальних номерів телефонів**, `backup`, SIM-даних або журналів з приватними даними.
4. Commit / push у вибрану гілку, наприклад `main`.

## 4. Налаштуйте адресу сайту — `baseurl`

У ZIP за замовчуванням:

```yaml
baseurl: ""
url: ""
```

Для репозиторію виду **`USERNAME.github.io`** (user/org site) зазвичай залишають `baseurl: ""`; сайт матиме адресу `https://USERNAME.github.io/`.

Для звичайного репозиторію **`smart-place-docs`** (project site) задайте:

```yaml
url: "https://USERNAME.github.io"
baseurl: "/smart-place-docs"
```

Змініть `USERNAME` на ваш GitHub login, а `smart-place-docs` — на **точну назву репозиторію**. Посилання між розділами в цьому комплекті зроблені відносно шляху сторінок; якщо надалі змінюєте структуру permalink чи ставите сайт у підпапку, перевірте навігацію. Для нестандартного домену потрібна окрема конфігурація URL/публікації.

## 5. Увімкніть Pages

У GitHub відкрийте **Settings → Pages**. У **Build and deployment → Source** оберіть **Deploy from a branch**. Далі задайте Branch `main` та Folder `/ (root)`, натисніть **Save**. GitHub почне публікацію після commit; у Settings → Pages буде URL сайту. Для розширеного custom build можна використовувати Actions, але для цієї Jekyll-структури зазвичай достатньо Branch source.

Офіційна довідка: [Configuring a publishing source](https://docs.github.com/en/pages/getting-started-with-github-pages/configuring-a-publishing-source-for-your-github-pages-site), [Adding a theme with Jekyll](https://docs.github.com/en/pages/setting-up-a-github-pages-site-with-jekyll/adding-a-theme-to-your-github-pages-site-using-jekyll).

## 6. Перевірка після публікації

- [ ] Головна відкривається з оформленням **Architect**.
- [ ] Видно діаграму `assets/architecture.svg`.
- [ ] Працюють переходи до чотирьох головних розділів і довідників.
- [ ] Кожен `[Завантажити ...]` відкриває точний файл у `downloads/`.
- [ ] Код RouterOS і блоки JSON відображаються моноширинно.
- [ ] У репозиторії **немає** приватного whitelist та знімків SMS Inbox.
- [ ] Перевірено сайт зі смартфона: заголовки, довгі таблиці, великі code blocks.

Якщо Jekyll пише `Remote Theme ... not found`, перевірте написання `remote_theme` та `plugins` і журнал Pages build. Якщо сторінка **без стилю**, перевірте, що збірку не вимкнули `.nojekyll` і що `_config.yml` на рівні `index.md`. Якщо сторінки відкриваються, а посилання ведуть не туди — перевірте `baseurl`, ім'я репозиторію та `permalink`.

## 7. Як підтримувати документацію актуальною

Внесення змін до RSC і зміна API ESP32 — це окремий реліз. У такому разі оновлюйте одночасно: `downloads/smart-place-install.rsc`, `downloads/smart-place.zip`, JSON-приклади, розділи `configuration`, `architecture`, `installation`, `usage`, а також `README.md`. У GitHub commit вказуйте, які зміни **перевірені на MikroTik**, а які лише написані. **Поточний реліз — документація без другого етапу фіксу `MEMORY_FULL`.**

**Готово:** [На головну](../) · [Повна інструкція встановлення](../installation/).
