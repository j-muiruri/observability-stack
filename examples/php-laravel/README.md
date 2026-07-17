# Instrumenting a Laravel app

Run these against a real (or throwaway test) Laravel app — `laravel new demo-app` if you want a clean sandbox first.

## 1. Install packages

```bash
composer require promphp/prometheus_client_php
composer require open-telemetry/opentelemetry-auto-laravel open-telemetry/exporter-otlp open-telemetry/transport-grpc
```

## 2. Metrics: expose /metrics

First bind a single shared `CollectorRegistry` in `app/Providers/AppServiceProvider.php` so the
middleware and the controller record/read the same metrics:

```php
use Prometheus\CollectorRegistry;
use Prometheus\Storage\InMemory;

public function register(): void
{
    $this->app->singleton(CollectorRegistry::class, function () {
        return new CollectorRegistry(new InMemory());
    });
}
```

Copy `MetricsMiddleware.php` into `app/Http/Middleware/` and `MetricsController.php` into `app/Http/Controllers/`.

Register the middleware globally in `app/Http/Kernel.php`:

```php
protected $middleware = [
    // ...
    \App\Http\Middleware\MetricsMiddleware::class,
];
```

Add the route in `routes/web.php`:

```php
Route::get('/metrics', [\App\Http\Controllers\MetricsController::class, 'index']);
```

Start the app so Prometheus has something to scrape:

```bash
php artisan serve --port=8000
```

Check it yourself before Prometheus does:

```bash
curl http://localhost:8000/metrics
```

You should see `http_requests_total` and `http_request_duration_seconds` lines. This is exactly what
`prometheus/prometheus.yml`'s `php-laravel-app` job scrapes.

## 3. Logs: structured JSON with a correlation ID

Copy `RequestIdMiddleware.php` into `app/Http/Middleware/` and register it (again in `$middleware`, put it
**first** so the ID exists before anything else logs).

In `config/logging.php`, add a JSON channel and make it (or a stack including it) your default:

```php
'channels' => [
    'json' => [
        'driver' => 'monolog',
        'handler' => Monolog\Handler\StreamHandler::class,
        'with' => ['stream' => storage_path('logs/laravel.json.log')],
        'formatter' => Monolog\Formatter\JsonFormatter::class,
    ],
],
```

Then set `LOG_CHANNEL=json` in `.env`. Every log line now includes `request_id` if you add it via the
middleware's context (see the file for the one-liner).

## 4. Traces: auto-instrumentation via OpenTelemetry

Add to `.env`:

```
OTEL_PHP_AUTOLOAD_ENABLED=true
OTEL_SERVICE_NAME=laravel-app
OTEL_TRACES_EXPORTER=otlp
OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4320
OTEL_PROPAGATORS=tracecontext
```

Port `4320` is the host-mapped OTLP HTTP port from `docker-compose.yml` — Alloy receives it there and
forwards to Tempo. No code changes needed beyond this — the `opentelemetry-auto-laravel` package hooks
into the framework automatically.

## 5. Sanity check

```bash
curl http://localhost:8000/            # generates a request + a trace
curl http://localhost:8000/metrics     # confirm counters increased
tail -f storage/logs/laravel.json.log  # confirm JSON logs with request_id are being written
```
