# ToolCabinetApi

Учебный сервер для дипломного проекта: связь ERP с инструментальным шкафом MATRIX-TM. Сейчас реализованы минимальный API, CI и локальный запуск через Docker. База данных и функции выдачи инструмента будут добавлены позже.

По решению пользователя используется **.NET 10**, хотя в исходном задании был указан .NET 8. Версия SDK задана в `global.json`: подходит стабильный SDK 10.0.100 или более новый из ветки 10.0.

## Запуск и проверка

Из корня репозитория, после установки .NET SDK 10:

```powershell
dotnet restore ToolCabinetApi.slnx
dotnet build ToolCabinetApi.slnx --configuration Release --no-restore
dotnet test ToolCabinetApi.slnx --configuration Release --no-build
dotnet run --project src/ToolCabinetApi --configuration Release --no-build --no-launch-profile --urls http://127.0.0.1:5080
```

В другом терминале:

```powershell
curl.exe -i http://127.0.0.1:5080/api/v1/health
```

Ожидается HTTP `200 OK` и JSON `{"status":"ok"}`. Маршрут проверяет только работу процесса API и приём запросов; SQL Server он не проверяет. Остановить сервер можно сочетанием Ctrl+C.

Интеграционный тест запускает настоящее приложение через `WebApplicationFactory`, отправляет HTTP-запрос и проверяет статус 200, тип содержимого и JSON с единственным полем `status`, равным `ok`.

На этом компьютере SDK 10 установлен локально в `.tools/dotnet`, системный SDK не менялся. Чтобы пользоваться им в текущем PowerShell:

```powershell
$env:PATH = "$PWD\.tools\dotnet;$env:PATH"
$env:DOTNET_ROOT = "$PWD\.tools\dotnet"
$env:DOTNET_CLI_HOME = "$PWD\.tools\cli"
$env:NUGET_PACKAGES = "$PWD\.tools\packages"
dotnet --version
```

Папка `.tools` исключена из Git. После клонирования на другом компьютере достаточно установить SDK 10 обычным способом.

## Запуск через Docker

Нужен запущенный Docker Desktop с WSL 2 и Linux-контейнерами. Установка SDK на Windows для этого способа не требуется: приложение собирается внутри Docker.

Из корня репозитория:

```powershell
cd C:\Users\Home\apimatrix
docker compose config --quiet
docker compose up --build -d
docker compose ps
curl.exe -i http://127.0.0.1:5080/api/v1/health
```

Ожидается HTTP `200 OK` и `{"status":"ok"}`. После запуска подождите несколько секунд перед проверкой. Если API ещё не готов, посмотрите логи и повторите запрос.

```powershell
# Логи; Ctrl+C прекращает просмотр, API продолжает работать
docker compose logs -f api

# Остановить и удалить контейнер проекта
docker compose down
```

После изменения кода снова выполните `docker compose up --build -d`. Docker пересоберёт образ и заменит контейнер. Эта команда сама по себе не запускает интеграционные тесты: их нужно запускать отдельно через `dotnet test` или CI.

Внешний порт можно изменить для текущего терминала, например если 5080 уже занят локальным запуском API:

```powershell
$env:TOOLCABINET_PORT = '5081'
docker compose up --build -d
curl.exe -i http://127.0.0.1:5081/api/v1/health
```

Для возврата к порту 5080 удалите переменную и пересоздайте контейнер:

```powershell
Remove-Item Env:TOOLCABINET_PORT -ErrorAction SilentlyContinue
docker compose up -d
```

`Dockerfile` собирает Release-версию в образе SDK 10 и переносит только опубликованное приложение в образ ASP.NET Core Runtime 10. Процесс работает от непривилегированного пользователя. `.dockerignore` передаёт в сборку только `global.json` и исходники API, исключая локальные `bin` и `obj`.

`compose.yaml` запускает сервис `api` из образа `toolcabinetapi:local`. Внутри используется порт 8080, снаружи по умолчанию 5080, доступный только с этого компьютера через 127.0.0.1. Контейнер перезапускается по политике `unless-stopped`, пока Docker работает. SQL Server на этом этапе не подключается. Проверка health выполняется внешним HTTP-запросом; состояние `Up` в Compose само по себе не подтверждает ответ API.

## CI в GitHub Actions

Конфигурация: `.github/workflows/ci.yml`. Облачный runner `ubuntu-latest` запускается при pull request в `main` и при push в `main`:

1. Устанавливает .NET SDK 10 и восстанавливает зависимости.
2. Собирает решение в Release и запускает интеграционный тест.
3. После успеха публикует API и загружает артефакт `ToolCabinetApi-<полный SHA коммита>`.

Внутри пакета есть `build-info.json` с SHA, репозиторием и номером запуска. В PR это SHA проверяемого merge-коммита GitHub. Результаты тестов сохраняются отдельно в TRX, в том числе при падении теста. При ошибке сборки или теста публикация приложения и загрузка его пакета пропускаются.

Результат после отправки изменений: [вкладка Actions](https://github.com/sheiiny/apimatrix/actions), процесс **ToolCabinetApi CI**. Для показа преподавателю нужно открыть PR из `server` в `main`, показать шаги проверки и скачать пакет из раздела Artifacts успешного запуска. После слияния процесс повторится для `main`.

Проверить публикацию локально можно так:

```powershell
dotnet publish src/ToolCabinetApi/ToolCabinetApi.csproj --configuration Release --no-build --output artifacts/publish -p:UseAppHost=false
dotnet artifacts/publish/ToolCabinetApi.dll --urls http://127.0.0.1:5080
```

Пакет требует установленный ASP.NET Core Runtime 10. Он запускается через `dotnet ToolCabinetApi.dll` и не содержит привязанный к ОС исполняемый файл. SQL Server, токены и пароли для текущего этапа не нужны.

## Состояние этапа

Готовы API с проверками и конфигурация CI; добавлена контейнеризация для локального запуска. Текущие изменения Docker не закоммичены и не отправлены. Статус запусков GitHub Actions нужно смотреть на вкладке Actions; в рамках этой работы удалённый запуск не выполнялся. CI пока публикует обычный пакет приложения, Docker-образ в нём ещё не собирается. Следующий шаг — добавить сборку и HTTP-проверку контейнера в CI, затем настроить CD и выделенный Windows runner. Автоматическое развёртывание на стенд пока не настроено.

Проверки Docker: `docker compose config --quiet`, `docker compose build` и `docker compose up --no-build -d` выполнены успешно. Запущенный контейнер вернул HTTP 200 и `{"status":"ok"}` по адресу `http://127.0.0.1:5080/api/v1/health`. Пользователь внутри контейнера имеет UID 1654 (не root). Контейнер оставлен работающим для локальной проверки; остановка — `docker compose down`.

Локально на Windows проверено с SDK 10.0.404 и runtime 10.0.15: восстановление зависимостей, Release-сборка (0 ошибок, 0 предупреждений), интеграционный тест (1 из 1), публикация пакета. Отдельный запуск API на http://127.0.0.1:51873/api/v1/health и опубликованного пакета на http://127.0.0.1:51874/api/v1/health дал HTTP 200 и {"status":"ok"}. Проверочные процессы остановлены. В этой среде сборка и тест потребовали запуска вне ограничений песочницы; для теста использовались дополнительные параметры --disable-build-servers -m:1.

Подход к интеграционному тесту основан на [документации ASP.NET Core](https://learn.microsoft.com/en-us/aspnet/core/test/integration-tests?view=aspnetcore-10.0), последовательность CI — на [документации GitHub Actions для .NET](https://docs.github.com/en/actions/tutorials/build-and-test-code/net).
