# Scion как ядро корпоративной агентной платформы
### Итоговый документ: описание платформы, карта control plane, безопасность, durable execution и готовность к production

*Версия 2026-08-26 · внутренний документ · черновик.*
*Основа: презентация «Корпоративная агентная платформа» (12 слайдов) + внешнее ревью. Все утверждения о возможностях Scion сверены с актуальным кодом upstream (`GoogleCloudPlatform/scion`, alpha) и опытом эксплуатации hosted-контура (Hub + GKE).*

---

## 0. Резюме

- **Scion** — открытая (Apache-2.0, Google) платформа оркестрации LLM-агентов, объединяющая многоагентную оркестрацию с собственным runtime/deploy-слоем. Работает **слоем выше** sandbox-рантаймов (Daytona/E2B/Modal): может использовать их и облака как исполнительный бэкенд, но сама решает задачу управления флотом агентов.
- Ревью справедливо указывает: деке не хватает полной картины **control plane**, **threat model**, **eval-слоя**, **durable execution** и **матрицы готовности**. Этот документ закрывает эти разделы — причём не «идеальными» списками, а фактическим состоянием Scion: что уже есть, что частично, чего нет.
- Главный вывод (уточнённая формулировка ревью): **Scion — сильное ядро** (исполнение, оркестрация, секреты, разделение identity, messaging, реестры). Для enterprise-production вокруг ядра достраивается **оболочка**: policy на инструменты, eval-слой, cost-квоты, усиленная изоляция, CI/CD-gates. Существенная часть оболочки **уже есть в самом Scion**, часть закрывается **соседними слоями** (корпоративный LLM-gateway, CI/CD, managed-sandbox-бэкенды), и лишь часть требует строительства с нуля.

---

## 1. Что такое Scion (базовые факты)

### 1.1 Позиционирование
Scion — платформа оркестрации LLM-агентов: backend-среда, которая берёт на себя весь жизненный цикл агентов и их взаимодействие. Отличительная черта — объединение многоагентной оркестрации с собственным рантайм/деплой-слоем, в отличие от «чистых» sandbox-рантаймов (Daytona/E2B/Modal), которые дают только изолированную песочницу и не знают про агентов. Scion работает слоем выше: он может использовать такие песочницы/облака как исполнительный бэкенд, но сам решает задачу управления флотом агентов.

Основное предназначение — организация взаимодействия и оркестрация агентов, т.е. полный контроль их жизненного цикла. Де-факто это backend для исполнения LLM-агентов: к системе обращаются по API/CLI с задачей «подготовь и запусти агента на таком-то брокере» (Docker / Kubernetes / Apple VZ; кросс-облачность — в развитии).

### 1.2 Статус
Open-source проект Google (Apache-2.0), стадия **alpha**: активная разработка, есть незавершённые/неподключённые части, частые обновления — «что работало вчера, сегодня может работать иначе». Практика эксплуатации подтверждает: обновления идут ежедневными пачками, включая волны security-hardening (см. §4.2).

### 1.3 Концептуальная модель (аналогия с Kubernetes)

| Kubernetes | Scion |
|---|---|
| control plane (apiserver + etcd) | **Hub** (API + БД состояния) |
| kubelet / узел | **Runtime Broker** (исполнитель) |
| pod | **Agent** (контейнер/под) |
| namespace | **Project** |
| декларативные манифесты | шаблоны + harness-configs (слоистая конфигурация) |

### 1.4 Архитектура агента
- **Harness** — контейнер-образ (Dockerfile) с готовым CLI-клиентом вендора. Поддерживаются: **claude, gemini-cli, codex, copilot, antigravity, opencode, hermes**, а также недавно добавленный **grok-build** (итого 8).
- **Harness-config** — именованная конфигурация поверх харнеса (auth, модель, env, gateway); версионируется по content-hash, бывает глобальной и проектной, переимпортируется из источника. Пример — конфигурация «quantori» (клиентский LLM-gateway).
- **Agent** — запущенный экземпляр: харнес-образ + harness-config + выделенный git-workspace + изолированная identity/секреты, поднятый как контейнер/под.

### 1.5 sciontool — агентский runtime-слой
Утилита, вшитая в образ (PID 1), через которую агент выполняет операции в своей среде, не подозревая о существовании Scion:
- init/супервизор процессов (сигналы, reaping);
- менеджмент sidecar-процессов (ready-checks, рестарты, «abandon» после серии падений);
- хуки харнеса → статус + телеметрия, статус-сигналы агента;
- телеметрия (OTLP-приёмник + форвардер в облако);
- auth и Git/GitHub (credential-helper, короткоживущие GitHub App-токены);
- secret manager (секреты доезжают до контейнера, не запекаются в образ);
- провижининг (резолв auth, запись конфигов, трансляция MCP, клон workspace);
- диагностика (doctor);
- GCP-identity через перехват metadata-сервера (iptables-DNAT);
- лимиты исполнения (max_duration → статус LIMITS_EXCEEDED).

Вся интеграция навешана вокруг агента — через хуки, env и перехваты, — поэтому сам CLI-клиент остаётся переносимым.

### 1.6 Ключевые возможности
- **MCP-endpoint**: постановка задач агентам без знания внутренностей Scion.
- **Единая точка входа (Hub)**: центральный API и хранилище состояния; создание и запуск агентов одним вызовом (в т.ч. нескольких сразу).
- **Взаимодействие агентов на естественном языке** через встроенный message-broker; координация по ролям («спроси у Тестировщика результаты и передай Архитектору»). Роли задаются шаблонами.
- **Настоящие sub-agent'ы**: работающий агент порождает под-агентов в рамках проекта (agent-token со scope AgentCreate; ancestry-цепочка фиксируется) — флот выстраивается динамически.
- **Отчуждаемость и мультиоблачность**: рантайм-абстракция (Docker/Kubernetes/Apple VZ), self-host; Runtime Broker как «раннер» на разных площадках.
- **Декларативная слоистая модель**: Harness → Harness-config → Agent с оверрайдами.
- **Деплой из коробки** (Docker/Kubernetes), sidecar-сервисы рядом с агентом.
- **Интеграция с Git**: проект = ссылка на репозиторий; агенты получают клон/worktree.
- **Общий workspace проекта**: shared-режимы (Git-содержимое, NFS, общий том GKE; S3 пока нет).
- **Поддержка ADK** (Agent Development Kit, Google): интеграция и Docker-шаблон для ADK-агентов.
- **Стандартные контейнерные логи** (docker logs / kubectl logs) без доп. настройки; телеметрия через OTLP.
- **Внешние каналы**: Telegram, Discord, Slack, Google Chat, MS Teams + **нативный web-chat** (пространства, треды, DM, presence, вложения). Отдельно — **A2A Protocol Bridge** (официальный a2a-go SDK) для Agent2Agent-взаимодействия и регистрации в Google Cloud Agent Registry.

---

## 2. Control plane: полная карта компонентов *(ответ на п. 2.4 ревью)*

Ревью требует явно показать компоненты control plane. Ниже — все 16, с фактическим состоянием в Scion. Легенда: ✅ есть · 🟡 частично · ❌ нет.

| # | Компонент | Что есть в Scion сегодня (факты из кода) | Статус |
|---|---|---|---|
| 1 | API Gateway / BFF | Hub REST API `/api/v1` + web-BFF (SSR); CLI и UI ходят в один API | ✅ |
| 2 | Identity & RBAC | OAuth/OIDC-логин (Google; настраиваемые OIDC-провайдеры), режимы доступа (domain-restricted / по приглашениям), роли пользователей (управление из UI), группы участников проекта + политики, admin-роли | 🟡 — ролевая модель есть; полноценного enterprise-RBAC (тонкие права, SCIM/каталоги) нет |
| 3 | Tenant / Project Registry | Реестр проектов: slug, git-remote, visibility, участники (members-группы), брокеры-провайдеры, метки, настройки, per-project секреты/env | ✅ |
| 4 | Agent Registry | Реестр агентов: фазы, applied-config, роли агентов, ancestry (кто кого породил), метки, статусы/активности | 🟡 — реестр *экземпляров* есть; каталога «одобренных типов агентов» с risk-level/approval-статусом нет (частично закрывают templates + harness-configs) |
| 5 | Template / Harness Catalog | Каталог из 8 харнессов; именованные harness-configs (глобальные/проектные, content-hash-версии, reimport из источника); шаблоны (версионируемые, GCS-хранилище, декларации секретов); user-scoped шаблоны | ✅ |
| 6 | Policy Engine | Authz-политики (группы/policies, seeded-политики с уважением удаления), authz-гарды на всех маршрутах + CI-проверка гардов, IAM-гейты для назначения GCP SA | 🟡 — *авторизация* есть; *runtime-политик* на tool-calls / egress / spend нет |
| 7 | Secrets Broker | Секрет-бэкенд: **шифрование at-rest**, scope-иерархия hub→user→project→broker, write-only API (значения не читаются назад), типы env/file/variable, injection-modes (always/as-needed), progeny-доступ (agent-ancestry + authz-проверка), **короткоживущие GitHub App-токены** с авто-refresh, редакция значений в логах, capture-auth (перехват логин-кред в секрет) | ✅ — одна из сильных сторон |
| 8 | Scheduler | Планировщик хаба (recurring-задачи, schedule-evaluator, scheduled events), размещение по брокерам/провайдерам, durable cross-node dispatch | 🟡 — размещение + cron есть; очередей задач/приоритетов/bin-packing нет |
| 9 | Runtime Broker Registry | Реестр брокеров: HMAC-регистрация, heartbeat, online/offline, capabilities, профили рантаймов, deployment-метки; исходящий control-channel (WS) | ✅ |
| 10 | State Store | SQLite (single-node) / Postgres (HA-контур), GCS для артефактов (шаблоны, harness-configs) | ✅ |
| 11 | Message Bus | Eventbus + fan-out на «спицы»: нативный web-chat, Telegram/Teams/Discord/Slack/Google Chat, A2A-мост; агент-агент сообщения со статусами доставки | ✅ |
| 12 | Audit Log | Событийная история, структурированные логи, записи dispatch-попыток | 🟡 — выделенного immutable-audit-журнала нет |
| 13 | Observability Backend | OTLP-приёмник в агенте → форвард в Cloud Monitoring (gen_ai-метрики: вызовы, токены in/out per project), /metrics хаба, стандартные контейнерные логи, /healthz | 🟡 — конвейер есть, дэшборды и полнота метрик дозревают |
| 14 | Evaluation Service | — | ❌ (см. §8) |
| 15 | Cost / Quota Manager | Только max_duration + LIMITS_EXCEEDED; бюджетов/квот в платформе нет | ❌/🟡 — закрывается LLM-gateway-слоем (см. §9) |
| 16 | Admin Console | Админ-UI: пользователи/роли, интеграции (каталог + установка), server-config, Runtimes & Profiles, федерация (JWKS) | ✅ |

**Итог по карте:** 8 ✅ · 6 🟡 · 2 ❌. Control plane в Scion существенно полнее, чем «identity, auth, state» из деки — но два системных гэпа (eval, cost) и «частичности» надо показывать явно.

---

## 3. Модель identity: четыре раздельных контура

Идеал ревью — `Human ≠ Agent ≠ Runtime ≠ Tool` — в Scion **уже реализован фактически**:

| Контур | Реализация в Scion |
|---|---|
| **Human user** | OAuth/OIDC (SSO), роли/группы, режимы доступа |
| **Agent identity** | Персональный JWT agent-token: subject=agent, project-scope, ancestry, ограниченные scopes (напр., AgentCreate для sub-агентов) |
| **Runtime identity** | Брокер: HMAC-ключи при регистрации + nonce-защита; транспортные OIDC-токены с истечением |
| **Tool credentials** | Короткоживущие GitHub App-токены (mint + expiry + refresh через credential-helper); GCP-identity per-agent через metadata-перехват (назначение SA гейтится IAM-проверками); ключи LLM — через секрет-скоупы или gateway |

Это сильный аргумент деки, который сейчас не проговорён.

---

## 4. Безопасность и threat model *(ответ на п. 2.5)*

### 4.1 Контролы, уже реализованные в Scion
- изоляция: контейнер/под на агента, отдельный git-worktree, отдельные креды;
- hardened-поды на k8s: non-root (uid 1000, FSGroup), запуск без привилегий;
- секреты: write-only, шифрование at-rest, скоупы, редакция в логах, не запекаются в образы;
- короткоживущие tool-токены (GitHub App), а не долгоживущие PAT;
- разделение identity (см. §3);
- authz-гарды на маршрутах + CI-проверка их наличия;
- человек-в-контуре: статус WAITING_FOR_INPUT + attach к терминалу агента.

### 4.2 Активный hardening upstream (важный сигнал зрелости)
За последние недели в upstream влиты: закрытие **22 обходов authz-гардов** + CI-гейт; патч **трёх P0 privilege-escalation**; **шифрование секрет-бэкенда at-rest**; исправление приоритета scope-резолва секретов. Платформа alpha, но security-долг гасится системно.

### 4.3 Таблица угроз (threat model)

| Угроза | Пример | Контролы в Scion сегодня | Чего не хватает |
|---|---|---|---|
| Cross-project leakage | агент видит чужой репозиторий | project-scoped секреты/env/agent-токены, members-группы, изолированные workspace | **per-project k8s namespace** (сегодня все агенты в одном namespace — известное ограничение кода), NetworkPolicy per project |
| Secret exfiltration | агент печатает токен | write-only секреты, шифрование at-rest, редакция в логах, scoped-инъекция, короткоживущие Git-токены | DLP/скан вывода агента, автоматическая ротация всех типов секретов |
| Prompt injection | инструкция в репо манипулирует агентом | контейнерная изоляция, human-in-the-loop (attach/approve по WAITING_FOR_INPUT) | policy-engine на tool-calls, формализованные approval-gates |
| Unsafe code | деструктивная команда | non-root поды, контейнерные границы, отдельный workspace | sandbox-уровни (gVisor/microVM), restricted shell, платформенные egress-политики |
| Runaway cost | бесконечный цикл | max_duration (таймер от старта контейнера) → LIMITS_EXCEEDED + нотификации; scale-to-zero инфраструктуры | квоты/бюджеты per tenant, idle-reaper по задачам |
| Bad PR | сырой код влит | процессное человеческое ревью | eval-gates, обязательные тест-ворота в платформе |

### 4.4 Честная поправка к деке
Слайд «Изоляция и федерация» обещает «изоляцию на уровне команды: namespaces и сетевые политики Kubernetes». **Сегодня это не так**: в Scion все агенты hosted-контура работают в одном namespace (per-project namespace конфигурацией не включается — подтверждено кодом резолвера рантаймов), сетевые политики платформа не управляет. Это надо либо переформулировать как целевое состояние, либо закрыть доработкой upstream.

---

## 5. Уровни изоляции рантайма *(Slide 4 из предложений ревью)*

| Tier | Описание | Scion сегодня |
|---|---|---|
| 0 | локальный контейнер | ✅ Docker / Apple VZ |
| 1 | Kubernetes pod | ✅ основной hosted-режим (GKE; non-root hardened) |
| 2 | restricted namespace per tenant/project | ❌ единый namespace (см. §4.4); NetworkPolicy — вне платформы |
| 3 | gVisor / Kata | ❌ нативно нет; достижимо на уровне кластера |
| 4 | Firecracker / microVM | ❌ нативно нет |
| 5 | managed sandbox (E2B/Modal-класс) | 🟡 архитектурно совместимо: брокер-абстракция позволяет подключить такой бэкенд как исполнителя (в развитии) |

---

## 6. Durable execution / recovery *(ответ на п. 2.7)*

Пункты чек-листа ревью — против фактического состояния:

| Требование | Scion сегодня | Статус |
|---|---|---|
| task checkpointing | на уровне платформы нет; на уровне харнесса — session-resume (напр., Claude Code `--resume`), workspace персистентен (git/NFS) | 🟡 |
| idempotent tool execution | нет гарантий | ❌ |
| resumable runs | resume/restart агента; воркспейс и home переживают рестарт | 🟡 |
| retry policy | ретраи диспатча (в т.ч. авто-repair рассинхрона хранилища конфигов), Restart=always у сервисов | 🟡 |
| failure classification | фазы агента (provisioning/running/stopped/error) + активности (COMPLETED / WAITING_FOR_INPUT / LIMITS_EXCEEDED / crashed) + причины отказа доставки | 🟡 |
| partial-result preservation | workspace/ветка сохраняются после смерти агента | ✅ |
| cancellation | stop/delete агента | ✅ |
| timeout | max_duration → LIMITS_EXCEEDED (важно: таймер тикает **от старта контейнера**, не от получения задачи) | ✅ (с оговоркой) |
| stuck-agent reaper | для *сообщений* есть: sweep застрявших pending (предупреждение >5 мин, авто-перевод в failed по TTL 24 ч); для агентов — duration-лимит | 🟡 |
| compensation logic | нет | ❌ |
| audit trail for recovery | журнал dispatch-попыток, durable cross-node dispatch (намерение фиксируется в БД и реконсилируется), boot-миграции под локами | 🟡 |

**Вывод:** фундамент durable-исполнения есть (durable dispatch + reconcile, статусы доставки, персистентные workspace, лимиты); «workflow-класса» механизмов (checkpoint/replay, идемпотентность, компенсации) нет — при необходимости их даёт интеграция с LangGraph-подобным слоем или доработка.

---

## 7. Observability *(п. 10 ревью)*

| Требование | Scion сегодня |
|---|---|
| logs | ✅ стандартные docker/kubectl logs + структурированные логи хаба |
| metrics | 🟡 OTLP-приёмник в агенте → Cloud Monitoring: gen_ai-метрики (вызовы API, токены in/out) с разбивкой по проектам; /metrics хаба; сводка по проекту в UI |
| traces | 🟡 OTLP-конвейер есть; трассировка «на весь жизненный цикл задачи» не собрана |
| per-agent timeline | 🟡 статусы/активности агента + события; единой timeline-страницы нет |
| tool/model calls, token usage | ✅ через gen_ai-метрики |
| cost | ❌ в платформе нет (см. §9) |
| errors / human interventions / PR outcomes | 🟡 ошибки и вмешательства видны в статусах/событиях; PR-исходы платформа не агрегирует |

Практическая оговорка: конвейер метрик рабочий, но дозревает (дэшборды, полнота серий) — закладывать в roadmap «OTel-дэшборды» из ревью справедливо.

---

## 8. Evaluation layer *(ответ на п. 2.6)* — гэп, и как его строить

**Статус: в Scion отсутствует.** Это честный ответ; человеческое код-ревью — процесс, а не eval-слой.

Что уже есть как фундамент для построения:
- метрики модели/токенов per project (Cloud Monitoring) → cost/интенсивность на задачу;
- статусы задач/агентов (COMPLETED/ERROR/LIMITS_EXCEEDED) → success-rate, human-intervention-rate;
- Git-контур → PR acceptance rate, rework;
- CI → test pass rate;
- слоистые harness-configs → A/B-сравнение моделей/харнессов на одинаковых шаблонах.

Предложение: отдельный **Evaluation Service** рядом с хабом (golden tasks, регрессия после апдейта модели/харнесса, security-checks вывода, policy-compliance), который потребляет уже существующие метрики и Git/CI-сигналы. В матрице готовности — «строить».

---

## 9. Cost governance *(п. 12 ревью)* — двухслойный ответ

**В самой платформе:** только max_duration + LIMITS_EXCEEDED (+ scale-to-zero кластера на уровне инфраструктуры). Бюджетов/квот/роутинга моделей нет — гэп.

**Практический паттерн, который уже работает в нашем контуре:** cost-контур выносится в **корпоративный LLM-gateway** (LiteLLM-класс), через который ходят все харнессы:

| Требование ревью | Где закрывается |
|---|---|
| token budget / budget alerts | gateway (per-key бюджеты, алерты) |
| model routing (дешёвая модель для простых задач) | gateway-роутинг |
| quota per tenant/project | per-project ключи gateway (у каждого проекта свой секрет) |
| cost per task / per accepted PR | строится на gen_ai-метриках + Git (часть eval-слоя, §8) |
| idle-agent reaper / automatic shutdown | max_duration + scale-to-zero; per-task reaper — доработка |
| spot/preemptible | уровень кластера |

Т.е. cost-governance — не «дыра», а **осознанное разнесение**: платёжные рычаги в gateway, лимиты исполнения в Scion, аналитика — в eval-слое. В деке это стоит показать именно так.

---

## 10. Полный жизненный цикл агента *(Slide 5 из предложений ревью)*

Расширение цепочки «Jira → PR» из деки до фактического пайплайна платформы:

```
Запрос (UI / CLI / API / MCP / мессенджер / A2A)
  → AuthZ (роли, группы, политики проекта)
  → Выбор шаблона + harness-config (+ DefaultHarnessAuth уровня хаба/проекта)
  → Резолв секретов по скоупам (hub → user → project → broker; write-only, шифрованы)
  → Планирование: выбор Runtime Broker (провайдеры проекта)
  → Провижининг: clone/worktree, home-sync, MCP-трансляция, auth-резолв, sidecars
  → Исполнение: sciontool (PID 1) — статусы, телеметрия, лимиты (max_duration)
  → Взаимодействие: сообщения агент↔агент, порождение sub-агентов (AgentCreate),
    human-in-the-loop (WAITING_FOR_INPUT → attach/approve)
  → Завершение: COMPLETED | ERROR | LIMITS_EXCEEDED (+ нотификации по триггерам)
  → Артефакты: коммиты/ветка/PR в Git (короткоживущие Git-токены)
  → Человеческое ревью → merge
  → Архивирование/удаление агента (workspace сохраняется)
```

Позиции «policy check» (runtime-политики инструментов) и «evaluate» (авто-оценка) — целевые вставки, сегодня их в цепочке нет.

---

## 11. Целевая архитектура: ядро Scion + enterprise-оболочка *(Slide 1–2 из предложений ревью)*

Схема из ревью, аннотированная фактическим статусом (✅ есть в Scion · 🟡 частично · ❌ достраивать · [G] закрывается gateway/соседним слоем):

```
Q-Agent Platform
├── Interaction Layer
│     Web UI ✅ · CLI ✅ · API/SDK ✅ · MCP ✅ · A2A ✅
│     Мессенджеры (Telegram/Slack/Discord/GChat/Teams) ✅ · Jira ❌ (интеграцию строить)
│
├── Agent Control Plane
│     Identity / SSO / RBAC 🟡      Agent Registry 🟡
│     Tenant/Project Registry ✅    Harness/Template Catalog ✅
│     Policy Engine 🟡 (authz есть; tool-политики ❌)
│     Secrets Broker ✅             Scheduler 🟡
│     Message Bus ✅                State Store ✅
│     Audit Log 🟡                  Cost Manager ❌ [G]
│
├── Execution Plane
│     Runtime Brokers ✅ · K8s Pods ✅ (non-root) · Docker/Apple VZ ✅
│     Per-agent Git Worktrees ✅ · NFS/общий том ✅ (S3 ❌)
│     Per-project namespaces ❌ · NetworkPolicy ❌
│     Sandboxes/microVM (E2B/Modal-класс) 🟡 как подключаемый бэкенд
│
├── Engineering Integration
│     Git ✅ · PR-контур ✅ (через агентов + GitHub App)
│     CI/CD ❌ (контракты строить) · Artifact/Package Registry ❌ · Jira ❌
│
├── AI Layer
│     8 харнессов ✅ · собственные harness-configs ✅
│     Model Router / бюджеты [G] — корпоративный LLM-gateway
│
└── Governance / Evaluation
      Logs/Metrics/Traces 🟡 · Human Approvals 🟡 (attach; gates формализовать)
      Evaluation Service ❌ · Cost Dashboards ❌ [G]+§8 · Compliance Evidence ❌
```

**Ключевая идея (совпадает с ревью):** Scion — execution/orchestration-ядро; enterprise-оболочка = Security/Governance + Evaluation + Cost + Delivery-lifecycle + Operations. Отличие от формулировки ревью: заметная часть «оболочки» уже внутри ядра (секреты, identity-разделение, message bus, реестры, admin-консоль).

---

## 12. Матрица готовности Scion *(Priority 2 ревью — заполнена фактами)*

| Возможность | Нужно для production | Scion сегодня | Гэп / действие |
|---|---|---|---|
| K8s runtime | да | **работает в бою** (GKE, приватный кластер, non-root поды, NFS-workspace) | cold-start-таймауты; кастомные образы на hardened-подах; ресурсные лимиты |
| Изоляция агентов | да | контейнер + worktree + креды per agent | per-project namespace ❌ (подтверждённое ограничение), NetworkPolicy, sandbox-tiers |
| RBAC / tenancy | да | роли, группы, политики, режимы доступа; активный authz-hardening | enterprise-RBAC, каталоги/SCIM |
| Секреты | да | ✅ сильный слой (at-rest шифрование, скоупы, короткоживущие токены, редакция) | ротация всех типов, DLP вывода |
| Eval-слой | да | ❌ | строить (§8), фундамент метрик есть |
| Cost-контроль | да | ❌ в платформе; [G] gateway закрывает бюджеты/квоты/роутинг | квоты в платформе, cost-per-task аналитика |
| Durable execution | да | 🟡 durable dispatch + reconcile, sweep, resume, персистентный workspace | checkpoint/replay, идемпотентность, компенсации |
| Observability | да | 🟡 OTLP→Cloud Monitoring (gen_ai), стандартные логи, /healthz | дэшборды, полнота метрик, trace задач |
| CI/CD-интеграция | да | ❌ описанной нет (только Git/PR через агентов, pre-start hooks) | контракты + gates |
| Policy engine (runtime) | да | 🟡 authz есть; tool-политик нет | строить enforcement-слой |
| HA control plane | желательно | 🟡 контур строится upstream: Postgres-режим, boot-локи, общие ключи подписи, federation, Helm-чарт | зрелость; single-VM+SQLite — стабильный режим сегодня |
| Admin/эксплуатация | да | ✅ админ-консоль, каталог интеграций, notifications | operating model (владельцы, эскалации) — организационно |

---

## 13. Сравнение с production-платформами *(разделы 5–6 ревью, сжато)*

| Платформа | Категория | Что берём как ориентир | Насколько близка к нашей цели |
|---|---|---|---|
| Google GEAP | enterprise agent platform | governance, Agent Registry/Identity/Gateway, eval («Optimize») | очень близко по обвязке; не про coding-swarm с worktrees |
| Microsoft Foundry Agent Service | managed agent runtime | hosted-агенты в контейнерах + identity, scaling, observability | близко по «platform ≠ контейнеры» |
| AWS Bedrock AgentCore | secure agent runtime | framework-agnostic runtime, governance, monitoring | близко по runtime-обвязке |
| LangGraph / LangSmith | orchestration framework | durable state: checkpoints, HITL, replay | образец для нашего гэпа §6 |
| CrewAI AMP | agent management | role-based teams, HITL-checkpoints, enterprise IAM | близко по «команде агентов», не по coding-runtime |
| E2B | sandbox infra | secure isolated execution | кандидат-бэкенд Execution Plane |
| Modal Sandboxes | sandbox/compute | untrusted-код, egress-контроль, масштаб | кандидат-бэкенд Execution Plane |
| Daytona | sandbox runtime | dev-песочницы | тот же слой, что E2B/Modal |
| **Scion** | harness-agnostic orchestrator | — | **максимально соответствует vision; статус alpha/pilot** |

**Ключевое отношение слоёв:** E2B/Modal/Daytona — *исполнительный слой* (песочницы, не знают про агентов); GEAP/Foundry/AgentCore — *enterprise-обвязка* (governance/runtime, не про git-worktree-swarm); LangGraph — *workflow-durability*. Scion — единственный из списка, кто совмещает оркестрацию флота с собственным deploy-слоем и при этом может использовать первую категорию как бэкенд и заимствовать паттерны второй и третьей. Ни одна зрелая платформа не закрывает нашу цель целиком — отсюда и стратегия «ядро + оболочка».

---

## 14. Роадмап: Pilot → Production *(Priority 3 / Slide 8 ревью)*

**Pilot-ready сегодня** (подтверждено эксплуатацией): внутренний репозиторий · некритичная кодовая база · ограниченное число агентов · без production-секретов · обязательное человеческое ревью · human-in-the-loop через attach.

**Production-ready требует:** enterprise-RBAC · runtime-policy engine · eval-gates · cost-квоты · audit-журнал · CI/CD-gates · per-project namespace + NetworkPolicy · HA control plane.

| Фаза | Содержание | Что добавляем |
|---|---|---|
| 1. Internal pilot *(текущая)* | 1 команда, внутренние репо, gateway-ключи | наблюдаемость (дэшборды), формализация approval-gates |
| 2. Controlled engineering use | несколько задач в реальной разработке | CI/CD-контракты, PR-gates, базовые KPI (§15) |
| 3. Multi-team platform | несколько команд/проектов | per-project namespace + NetworkPolicy, enterprise-RBAC, Agent Registry с approval, квоты |
| 4. Enterprise production | критичные кодовые базы | eval-слой с gates, audit-журнал, HA control plane, runtime-policy engine |
| 5. Client-facing / regulated | клиентские контуры | compliance-evidence, изоляция Tier 3+ (sandbox/microVM), федерация A2A |

---

## 15. KPI платформы *(Priority 5 ревью)*

Task success rate · PR acceptance rate · Human rework rate · Test pass rate · Security findings per PR · Cost per accepted change · Time-to-first-PR · Agent idle cost · Failure recovery rate · Model/harness A/B comparison.

Источники данных уже существуют: статусы задач (Scion) + gen_ai-метрики (Cloud Monitoring) + Git/CI. Сведение — задача eval-слоя (§8).

---

## 16. Соответствие разделов документа слайдам деки

| Предложение ревью | Раздел документа |
|---|---|
| Slide 1 — Target Architecture | §11 |
| Slide 2 — Control Plane Components | §2 (+§3) |
| Slide 3 — Security & Threat Model | §4 |
| Slide 4 — Runtime Isolation Tiers | §5 |
| Slide 5 — Agent Lifecycle | §10 |
| Slide 6 — Evaluation Layer | §8 |
| Slide 7 — Cost & Capacity Governance | §9 |
| Slide 8 — Roadmap Pilot → Production | §14 |
| Priority 2 — Readiness matrix | §12 |
| Priority 5 — KPIs | §15 |

Также: поправить слайд «Изоляция и федерация» (см. §4.4 — namespaces сегодня целевое состояние, не факт) и добавить в слайд харнессов grok-build (8-й).

---

## 17. Итоговая формулировка

> Предлагаемая платформа — сильная pilot-концепция с необычно зрелым для alpha ядром: Scion уже даёт исполнение, оркестрацию, secrets-broker, разделение identity, message bus, реестры и админ-контур. Для production-grade enterprise-платформы вокруг ядра достраивается оболочка: runtime-policy, evaluation, cost-квоты (частично — LLM-gateway), усиленная изоляция (per-project namespaces, sandbox-tiers), CI/CD-gates, audit и HA. Ни одна существующая production-платформа (GEAP, Foundry, AgentCore, LangGraph, CrewAI, E2B/Modal) не закрывает эту цель целиком — Scion ближе всех к vision и допускает использование остальных как слоёв.
