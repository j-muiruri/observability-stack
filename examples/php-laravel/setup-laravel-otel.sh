#!/usr/bin/env bash
set -e

# ----------------------------------------------------------------------
# 0. Automate Redis Server & PHP Extension Installations (Linux / macOS)
# ----------------------------------------------------------------------
echo "==> Checking and installing system dependencies (Redis & PHP extensions)..."

OS_TYPE="$(uname -s)"

# 0a. Install Redis Server if not present
if ! command -v redis-cli &> /dev/null; then
    echo "--> Redis Server not found. Installing..."
    if [ "$OS_TYPE" = "Linux" ]; then
        sudo apt-get update -y
        sudo apt-get install -y redis-server
        sudo systemctl enable redis-server || true
        sudo systemctl start redis-server || true
    elif [ "$OS_TYPE" = "Darwin" ]; then
        brew install redis
        brew services start redis
    fi
else
    echo "--> Redis Server is already installed."
fi

# 0b. Helper to dynamically detect PHP versions and install extensions across ALL versions
install_php_extension_all_versions() {
    local ext_name=$1
    echo "--> Processing PHP extension '${ext_name}' across all installed PHP versions..."

    if [ "$OS_TYPE" = "Linux" ]; then
        # Ensure build tools are present
        sudo apt-get update -y
        sudo apt-get install -y php-pear autoconf build-essential zlib1g-dev re2c

        # Find all PHP versions installed under /etc/php/
        PHP_VERSIONS=$(ls /etc/php/ 2>/dev/null || true)

        if [ -z "$PHP_VERSIONS" ]; then
            # Fallback to active system PHP if directory structure is non-standard
            PHP_VERSIONS=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')
        fi

        for VER in $PHP_VERSIONS; do
            echo "---> Checking PHP ${VER} for extension ${ext_name}..."

            # Ensure php-dev for this specific version is installed
            sudo apt-get install -y "php${VER}-dev" "php${VER}-xml" 2>/dev/null || true

            # Check if apt extension package exists first
            if sudo apt-get install -y "php${VER}-${ext_name}" 2>/dev/null; then
                echo "---> Installed php${VER}-${ext_name} via apt."
            else
                # Fallback: Compile from PECL source for this specific version
                echo "---> Compiling ${ext_name} specifically for PHP ${VER}..."
                
                BUILD_DIR=$(mktemp -d)
                (
                    cd "$BUILD_DIR"
                    pecl download "$ext_name" >/dev/null 2>&1 || true
                    TAR_FILE=$(ls "${ext_name}-"*.tgz 2>/dev/null | head -n 1)
                    
                    if [ -n "$TAR_FILE" ]; then
                        tar -xzf "$TAR_FILE"
                        cd "${ext_name}-"*
                        
                        # Target exact PHP version tooling
                        "phpize${VER}" --clean >/dev/null 2>&1 || true
                        "phpize${VER}"
                        ./configure --with-php-config="php-config${VER}"
                        make -j"$(nproc)"
                        sudo make install

                        # Ensure configuration link/ini exists
                        MODS_DIR="/etc/php/${VER}/mods-available"
                        INI_FILE="${MODS_DIR}/${ext_name}.ini"
                        if [ -d "$MODS_DIR" ]; then
                            echo "extension=${ext_name}.so" | sudo tee "$INI_FILE" > /dev/null
                            sudo phpenmod -v "$VER" "$ext_name" 2>/dev/null || true
                        fi
                    else
                        echo "---> Warning: Could not download PECL package for ${ext_name}"
                    fi
                )
                rm -rf "$BUILD_DIR"
            fi
        done

    elif [ "$OS_TYPE" = "Darwin" ]; then
        # macOS handling via PECL
        pecl install "$ext_name" || true
    fi
}

# Install OpenTelemetry & Redis PHP extensions across all installed PHP versions
install_php_extension_all_versions "opentelemetry"
install_php_extension_all_versions "redis"

# ----------------------------------------------------------------------
# 1. Directory & Environment Check
# ----------------------------------------------------------------------
TARGET_DIR="${1:-.}"

if [ ! -d "$TARGET_DIR" ]; then
    echo "Error: Directory '$TARGET_DIR' does not exist."
    exit 1
fi

cd "$TARGET_DIR"

if [ ! -f "artisan" ]; then
    echo "Error: Directory '$TARGET_DIR' does not appear to be a Laravel project (artisan not found)."
    exit 1
fi

echo "==> Setting up OpenTelemetry & Prometheus instrumentation in: $(pwd)"

# ----------------------------------------------------------------------
# 2. Update & Install Composer Packages (Includes Predis)
# ----------------------------------------------------------------------
echo "==> Updating Composer packages..."
composer update -vvv

echo "==> Installing Composer dependencies..."
composer require predis/predis \
                 promphp/prometheus_client_php \
                 open-telemetry/opentelemetry-auto-laravel \
                 open-telemetry/exporter-otlp

# ----------------------------------------------------------------------
# 3. Create Middleware and Controller Stubs
# ----------------------------------------------------------------------
echo "==> Creating Middleware and Controller files..."

mkdir -p app/Http/Middleware app/Http/Controllers

# 3a. Metrics Middleware Stub
cat << 'EOF' > app/Http/Middleware/MetricsMiddleware.php
<?php

namespace App\Http\Middleware;

use Closure;
use Illuminate\Http\Request;
use Prometheus\CollectorRegistry;

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
            '',
            'http_requests_total',
            'Total HTTP requests',
            ['method', 'route', 'status']
        )->inc([$request->method(), $route, $status]);

        $registry->getOrRegisterHistogram(
            '',
            'http_request_duration_seconds',
            'HTTP request duration in seconds',
            ['method', 'route'],
            [0.01, 0.05, 0.1, 0.3, 0.5, 1, 2, 5]
        )->observe($duration, [$request->method(), $route]);

        return $response;
    }
}
EOF

# 3b. Request ID Middleware Stub
cat << 'EOF' > app/Http/Middleware/RequestIdMiddleware.php
<?php

namespace App\Http\Middleware;

use Closure;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Log;
use Illuminate\Support\Str;
use OpenTelemetry\API\Trace\Span;

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
EOF

# 3c. Metrics Controller Stub
cat << 'EOF' > app/Http/Controllers/MetricsController.php
<?php

namespace App\Http\Controllers;

use Illuminate\Http\Response;
use Prometheus\CollectorRegistry;
use Prometheus\RenderTextFormat;

class MetricsController extends Controller
{
    public function index(CollectorRegistry $registry): Response
    {
        $renderer = new RenderTextFormat();

        return response($renderer->render($registry->getMetricFamilySamples()))
            ->header('Content-Type', RenderTextFormat::MIME_TYPE);
    }
}
EOF

# ----------------------------------------------------------------------
# 4. Inject CollectorRegistry into AppServiceProvider
# ----------------------------------------------------------------------
echo "==> Updating AppServiceProvider.php..."
PROVIDER_FILE="app/Providers/AppServiceProvider.php"

if [ -f "$PROVIDER_FILE" ]; then
    if ! grep -q "CollectorRegistry" "$PROVIDER_FILE"; then
        sed -i '/namespace App\\Providers;/a \
use Prometheus\\CollectorRegistry;\nuse Prometheus\\Storage\\Redis;' "$PROVIDER_FILE"

        SINGLETON_CODE="        \$this->app->singleton(CollectorRegistry::class, function () {\n            Redis::setDefaultOptions([\n                'host' => config('database.redis.default.host', '127.0.0.1'),\n                'port' => config('database.redis.default.port', 6379),\n                'password' => config('database.redis.default.password', null),\n                'database' => 0,\n                'timeout' => 0.1,\n                'read_timeout' => 10,\n                'persistent_connections' => false,\n            ]);\n            return new CollectorRegistry(new Redis());\n        });"

        awk -v code="$SINGLETON_CODE" '
          /public function register/ { found=1 }
          found && /\{/ {
            print $0
            print code
            found=0
            next
          }
          { print }
        ' "$PROVIDER_FILE" > "$PROVIDER_FILE.tmp" && mv "$PROVIDER_FILE.tmp" "$PROVIDER_FILE"
    fi
fi

# ----------------------------------------------------------------------
# 5. Register Middleware (Detect Laravel 11 vs Older)
# ----------------------------------------------------------------------
if [ -f "bootstrap/app.php" ] && grep -q "withMiddleware" "bootstrap/app.php"; then
    echo "==> Registering Middleware in bootstrap/app.php (Laravel 11+)..."
    BOOTSTRAP_FILE="bootstrap/app.php"
    
    if ! grep -q "MetricsMiddleware" "$BOOTSTRAP_FILE"; then
        sed -i '/->withMiddleware(function (Middleware $middleware) {/a \        $middleware->append(\\App\\Http\\Middleware\\MetricsMiddleware::class);\n        $middleware->prepend(\\App\\Http\\Middleware\\RequestIdMiddleware::class);' "$BOOTSTRAP_FILE"
    fi
elif [ -f "app/Http/Kernel.php" ]; then
    echo "==> Registering Middleware in app/Http/Kernel.php (Laravel 10 or below)..."
    KERNEL_FILE="app/Http/Kernel.php"
    
    if ! grep -q "MetricsMiddleware" "$KERNEL_FILE"; then
        sed -i '/protected \$middleware = \[/a \        \\App\\Http\\Middleware\\RequestIdMiddleware::class,\n        \\App\\Http\\Middleware\\MetricsMiddleware::class,' "$KERNEL_FILE"
    fi
fi

# ----------------------------------------------------------------------
# 6. Add /metrics Route
# ----------------------------------------------------------------------
echo "==> Adding /metrics route to routes/web.php..."
ROUTES_FILE="routes/web.php"

if ! grep -q "MetricsController" "$ROUTES_FILE"; then
    cat << 'EOF' >> routes/web.php

Route::get('/metrics', [\App\Http\Controllers\MetricsController::class, 'index']);
EOF
fi

# ----------------------------------------------------------------------
# 7. Configure Logging
# ----------------------------------------------------------------------
echo "==> Configuring config/logging.php..."
LOGGING_FILE="config/logging.php"

if [ -f "$LOGGING_FILE" ] && ! grep -q "'json' =>" "$LOGGING_FILE"; then
    JSON_CHANNEL="        'json' => [\n            'driver' => 'monolog',\n            'handler' => Monolog\\\\Handler\\\\StreamHandler::class,\n            'with' => ['stream' => storage_path('logs/laravel.json.log')],\n            'formatter' => Monolog\\\\Formatter\\\\JsonFormatter::class,\n        ],"
    sed -i "/'channels' => \[/a $JSON_CHANNEL" "$LOGGING_FILE"
fi

# ----------------------------------------------------------------------
# 8. Configure .env (Daily + Stack + OTEL + Redis Auth)
# ----------------------------------------------------------------------
echo "==> Updating .env parameters..."
ENV_FILE=".env"

if [ -f "$ENV_FILE" ]; then
    # Set LOG_CHANNEL=daily
    if grep -q "^LOG_CHANNEL=" "$ENV_FILE"; then
        sed -i 's/^LOG_CHANNEL=.*/LOG_CHANNEL=daily/' "$ENV_FILE"
    else
        echo "LOG_CHANNEL=daily" >> "$ENV_FILE"
    fi

    # Set LOG_STACK=single,json
    if grep -q "^LOG_STACK=" "$ENV_FILE"; then
        sed -i 's/^LOG_STACK=.*/LOG_STACK=single,json/' "$ENV_FILE"
    else
        echo "LOG_STACK=single,json" >> "$ENV_FILE"
    fi

    # Ensure REDIS_HOST, REDIS_PORT, REDIS_CLIENT exist
    grep -q "^REDIS_CLIENT=" "$ENV_FILE" || echo "REDIS_CLIENT=phpredis" >> "$ENV_FILE"
    grep -q "^REDIS_HOST=" "$ENV_FILE" || echo "REDIS_HOST=127.0.0.1" >> "$ENV_FILE"
    grep -q "^REDIS_PORT=" "$ENV_FILE" || echo "REDIS_PORT=6379" >> "$ENV_FILE"
    grep -q "^REDIS_PASSWORD=" "$ENV_FILE" || echo "REDIS_PASSWORD=null" >> "$ENV_FILE"

    # Append OpenTelemetry env variables if not present
    if ! grep -q "OTEL_PHP_AUTOLOAD_ENABLED" "$ENV_FILE"; then
        cat << 'EOF' >> "$ENV_FILE"

# OpenTelemetry Configuration
OTEL_PHP_AUTOLOAD_ENABLED=true
OTEL_SERVICE_NAME=laravel-app
OTEL_TRACES_EXPORTER=otlp
OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4320
OTEL_PROPAGATORS=tracecontext
EOF
    fi
fi

# ----------------------------------------------------------------------
# 9. Configure .File Permissions for Laravel Storage & Logs
# ----------------------------------------------------------------------

echo "==> Creating storage and bootstrap/cache directories if they don't exist..."
mkdir -p storage/framework/cache/data
mkdir -p bootstrap/cache

echo "==> Change ownership to web server user (www-data)"
chown -R www-data:www-data storage bootstrap/cache

echo "==> Setting permissions for storage and logs..."
chmod -R 775 storage bootstrap/cache

echo "----------------------------------------------------------------------"
echo "Success! Laravel project has been instrumented across all PHP versions."
echo "----------------------------------------------------------------------"