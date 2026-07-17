<?php

namespace App\Http\Middleware;

use Closure;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Log;
use Illuminate\Support\Str;
use OpenTelemetry\API\Trace\Span;

/**
 * Ensures every request has a correlation ID and that every subsequent log
 * line in the request includes it — this is what lets you jump from a log
 * line to "everything else that happened in this request" in Grafana.
 *
 * If the OpenTelemetry auto-instrumentation is active (see README step 4),
 * we reuse the active trace's trace_id as the correlation ID so logs and
 * traces share the exact same identifier. Otherwise we fall back to a UUID.
 */
class RequestIdMiddleware
{
    public function handle(Request $request, Closure $next)
    {
        $traceId = null;

        if (class_exists(Span::class)) {
            $spanContext = Span::getCurrent()->getContext();
            if ($spanContext->isValid()) {
                $traceId = $spanContext->getTraceId();
            }
        }

        $requestId = $traceId ?? (string) Str::uuid();

        $request->attributes->set('request_id', $requestId);

        Log::withContext([
            'request_id' => $requestId,
            'trace_id' => $traceId,
        ]);

        $response = $next($request);
        $response->headers->set('X-Request-Id', $requestId);

        return $response;
    }
}
