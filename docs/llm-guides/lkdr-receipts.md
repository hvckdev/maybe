# LKDR («Мои чеки онлайн») — чеки и импорт расходов

Этот документ описывает экспериментальную интеграцию с [lkdr.nalog.ru](https://lkdr.nalog.ru/) — сервисом ФНС «Мои чеки онлайн». Он предназначен для разработчиков и агентов, которые продолжают работу в новом контексте.

> [!WARNING]
> LKDR не предоставляет публичного документированного партнёрского API. Реализация использует API, которым пользуется веб-клиент LKDR. Контракт может измениться без предупреждения; перед выпуском или крупными изменениями нужно проверить flow на собственном тестовом аккаунте.

## Что умеет текущая реализация

На странице **Transactions → Receipts**:

1. Администратор семьи вводит телефон, привязанный к LKDR.
2. Приложение запрашивает SMS-код у LKDR.
3. Администратор вводит SMS-код в приложении.
4. После подтверждения сохраняется refresh token подключения.
5. Кнопка **Update receipts** ставит в очередь фоновую синхронизацию.
6. Полученные чеки отображаются в этой вкладке.
7. Пользователь выбирает счёт и импортирует чек как обычную расходную `Entry` / `Transaction`.

Подключение, обновление и отключение требуют `Current.user.admin?`. Просматривать чеки могут все пользователи семьи с доступом к странице транзакций. Импорт требует обычного права записи в выбранный счёт через `require_account_permission!`.

## Доменные сущности

```text
Family
 ├── has_one  LkdrConnection
 └── has_many LkdrReceipt

LkdrConnection
 ├── phone
 ├── refresh_token             # encrypted when AR encryption is configured
 ├── challenge_token           # encrypted when AR encryption is configured
 ├── challenge_expires_at
 ├── status: pending | connected | syncing | requires_reauth
 ├── last_synced_at
 └── last_error

LkdrReceipt
 ├── family
 ├── external_key              # LKDR fiscal/composite key, unique per family
 ├── merchant_name / merchant_inn
 ├── purchased_at / total_amount / currency
 ├── fiscal_* fields
 ├── raw_payload               # encrypted when AR encryption is configured
 └── entry                     # created only after explicit import
```

Миграции:

- `db/migrate/20260808194000_create_lkdr_receipts.rb`
- `db/migrate/20260808195000_create_lkdr_connections.rb`

## Идемпотентность импорта

`LkdrReceipt#import_into!` создаёт расход с:

```ruby
source: "lkdr"
external_id: receipt.external_key
amount: receipt.total_amount # положительное значение = expense в этой кодовой базе
```

В `entries` уже есть уникальный индекс на `[account_id, source, external_id]`. Поэтому повторный импорт того же чека в один и тот же счёт не создаст дубликат. Сам `LkdrReceipt` также хранит `entry_id` и после успешного импорта больше не предлагает кнопку импорта.

Не изменяйте это на fuzzy matching по сумме/дате/названию: два равных чека в одном магазине — валидный сценарий.

## Архитектура и ключевые файлы

| Ответственность | Файл |
| --- | --- |
| HTTP-клиент закрытого API | `app/models/lkdr_connection/client.rb` |
| SMS flow, токены, нормализация и upsert чеков | `app/models/lkdr_connection.rb` |
| Модель чека и импорт в расход | `app/models/lkdr_receipt.rb` |
| Фоновая загрузка чеков | `app/jobs/lkdr_receipt_sync_job.rb` |
| HTTP actions подключения | `app/controllers/lkdr_connections_controller.rb` |
| Импорт отдельного чека | `app/controllers/lkdr_receipts_controller.rb` |
| Вкладка чеков | `app/views/transactions/_receipts.html.erb` |
| Подключение вкладки | `app/views/transactions/index.html.erb` |
| Routes | `config/routes.rb` |
| Фильтрация secret-параметров в логах | `config/initializers/filter_parameter_logging.rb` |

Маршруты:

```text
POST   /lkdr_connection           # отправить SMS
POST   /lkdr_connection/verify    # проверить SMS-код
POST   /lkdr_connection/sync      # enqueue синхронизации
DELETE /lkdr_connection           # удалить подключение и токены
POST   /lkdr_receipts/:id/import  # импортировать чек в выбранный счёт
```

## Наблюдавшийся API-контракт

Контракт извлечён из публично доступного JavaScript-бандла LKDR, а не из официальной API-документации.

| Операция | Endpoint | Тело / результат |
| --- | --- | --- |
| Начать SMS challenge | `POST /api/v2/auth/challenge/phone/start` | `{ phone, captchaToken, deviceInfo }` → `challengeToken`, время истечения |
| Подтвердить код | `POST /api/v1/auth/challenge/phone/verify` | `challengeToken`, `phone`, `code`, `deviceInfo` → `token`, `refreshToken` |
| Обновить access token | `POST /api/v1/auth/token` | `refreshToken`, `deviceInfo` → `token`, иногда новый `refreshToken` |
| Список чеков | `POST /api/v1/receipt` | Bearer access token; `limit`, `offset`, `dateFrom`, `dateTo`, `orderBy`, `inn` |
| Детализация чека | `POST /api/v1/receipt/fiscal_data` | `{ key }`; пока не используется |

`LkdrConnection::Client::DEVICE_INFO` соответствует ожидаемой структуре web-клиента. Перед SMS challenge LKDR требует Yandex SmartCaptcha; UI загружает публичный site key, наблюдавшийся в web-клиенте LKDR. Он может быть привязан к домену или перестать работать без уведомления. Не отправляйте токены или SMS-коды в логи, исключения, Sentry metadata, задачи Sidekiq или клиентский JavaScript.

## Синхронизация

`LkdrConnection#sync_later` переводит запись в `syncing` и ставит `LkdrReceiptSyncJob` в очередь. Job вызывает `sync_receipts!`:

1. Обменивает refresh token на access token.
2. Запрашивает страницы чеков по 100 записей через `offset`.
3. Находит или создаёт `LkdrReceipt` по `[family_id, external_key]`.
4. Не трогает уже импортированные `entry_id`.
5. При `401`/`403` переводит подключение в `requires_reauth`.

`raw_payload` сохраняется намеренно: он помогает адаптировать нормализацию при изменении API. При Active Record Encryption он шифруется. Не использовать `upsert` для `raw_payload`: bulk-upsert обходит шифрование Active Record. В текущем коде применяется `find_or_initialize_by` + `save!`.

## Безопасность и приватность

- Никогда не просите пользователя прислать SMS-код, access token или refresh token в чат, issue, PR или поддержку.
- `phone` и `code` добавлены в `filter_parameter_logging.rb`; `token` уже фильтровался по частичному совпадению.
- SMS-код не сохраняется. Challenge token и refresh token шифруются, если доступен `ActiveRecordEncryptionConfig`.
- При отключении удаляется `LkdrConnection` вместе с токенами. Чеки и уже импортированные расходы сохраняются.
- Ошибки background job логируют только ID подключения и класс ошибки, а не сообщение внешнего API: сообщения могут содержать персональные данные.
- Не добавляйте автоматический частый polling. Сейчас обновление запускается пользователем вручную.

## Тесты и валидация

Тесты:

- `test/models/lkdr_connection_test.rb` — SMS challenge, сохранение token и синхронизация одного чека через mock клиента.
- `test/models/lkdr_receipt_test.rb` — импорт чека в расход и защита от повторного импорта.

Перед запуском этих тестов в окружении должны быть применены две LKDR-миграции выше.

Проверки, уже выполненные при добавлении feature:

- Ruby syntax для модели, client, controller, job, миграций и tests;
- YAML локализаций;
- `git diff --check`;
- проверка маршрутов `bin/rails routes -g lkdr`.

Полный end-to-end flow с реальным LKDR-аккаунтом **ещё не выполнялся**. Это необходимо сделать локально через UI, не передавая данные авторизации другим людям или агентам.

## Вероятные следующие улучшения

1. Проверить на тестовом аккаунте реальный формат `challengeTokenExpiresIn` и всех полей списка чеков.
2. Добавить контролируемую обработку rate limit, если сервис её вернёт.
3. Использовать `POST /api/v1/receipt/fiscal_data` для отображения товарных позиций в drawer чека. Не нужно автоматически создавать отдельные расходы по позициям без UX для split transaction.
4. Добавить сопоставление чека с существующей банковской транзакцией как отдельный review-flow. Не создавать автоматический fuzzy merge по одному совпадению суммы.
5. После подтверждения стабильности контракта решить, нужна ли ограниченная периодическая синхронизация. Приоритет — ручной sync и сохранность приватных данных.
