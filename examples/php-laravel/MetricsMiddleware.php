<?php

namespace App\Http\Middleware;

use Closure;
use Illuminate\Http\Request;
use Prometheus\CollectorRegistry;
use Prometheus\Storage\InMemory;

/**
 * Records RED-method metrics (Rate, Errors, Duration) for every request.
 *
 * NOTE ON STORAGE: this uses the InMemory adapter, which is fine for
 * `php artisan serve` (single long-running process) but will NOT accumulate
 * correctly behind php-fpm, where each worker is a separate process. For
 * php-fpm/production, switch to the Redis adapter (you already run Redis):
 *
 *   use Prometheus\Storage\Redis;
 *   Redis::setDefaultOptions(['host' => env('REDIS_HOST', '127.0.0.1')]);
 *   $registry = new CollectorRegistry(new Redis());
 */
class MetricsMiddleware
{
    public function handle(Request $request, Closure $next)
    {
        $start = microtime(true);

        $response = $next($request);

        $duration = microtime(true) - $start;
        $route = optional($request->route())->uri() ?? $request->path();
        $status = (string) $response->getStatusCode();

        $registry = app(CollectorRegistry::class);

        $registry->getOrRegisterCounter(
            'app',
            'http_requests_total',
            'Total HTTP requests',
            ['method', 'route', 'status']
        )->inc([$request->method(), $route, $status]);

        $registry->getOrRegisterHistogram(
            'app',
            'http_request_duration_seconds',
            'HTTP request duration in seconds',
            ['method', 'route'],
            [0.01, 0.05, 0.1, 0.3, 0.5, 1, 2, 5]
        )->observe($duration, [$request->method(), $route]);

        return $response;
    }
}
