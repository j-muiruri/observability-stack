# Instrumenting a Java app

Two separate things happen here: metrics (via Micrometer/Actuator, in-process) and traces (via the
OpenTelemetry Java agent, zero code changes). Do both.

## 1. Metrics: Micrometer + Actuator (Spring Boot apps)

`pom.xml`:

```xml
<dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-actuator</artifactId>
</dependency>
<dependency>
    <groupId>io.micrometer</groupId>
    <artifactId>micrometer-registry-prometheus</artifactId>
</dependency>
```

`src/main/resources/application.yml`:

```yaml
management:
  endpoints:
    web:
      exposure:
        include: prometheus, health
  endpoint:
    prometheus:
      enabled: true
  metrics:
    tags:
      service: java-app          # matches the `service` label used across dashboards/alerts
    distribution:
      percentiles-histogram:
        http.server.requests: true   # needed for p95/p99 latency queries

server:
  port: 8080
```

This alone gets you request rate/latency/error counts (`http_server_requests_seconds_count/_sum/_bucket`),
full JVM metrics (heap, GC pause time, thread states), and — if you're on Spring + HikariCP —
connection pool metrics, all at `/actuator/prometheus`, which is exactly what
`prometheus/prometheus.yml`'s `java-app` job scrapes.

**Not using Spring Boot?** Use the standalone JMX exporter instead: download
`jmx_prometheus_javaagent.jar` and run with
`-javaagent:jmx_prometheus_javaagent.jar=8080:config.yaml` (config.yaml controls which MBeans get
exposed — start from the exporter's default Tomcat/Kafka examples on its GitHub releases page).

## 2. Traces: OpenTelemetry Java agent (zero code changes)

Download the agent jar (one file, no code changes):

```bash
curl -L -o opentelemetry-javaagent.jar \
  https://github.com/open-telemetry/opentelemetry-java-instrumentation/releases/latest/download/opentelemetry-javaagent.jar
```

Run your app with it attached:

```bash
java -javaagent:opentelemetry-javaagent.jar \
     -Dotel.service.name=java-app \
     -Dotel.exporter.otlp.endpoint=http://localhost:4320 \
     -Dotel.exporter.otlp.protocol=http/protobuf \
     -Dotel.resource.attributes=deployment.environment=local \
     -Dotel.instrumentation.logback-mdc.enabled=true \
     -jar target/your-app.jar
```

Port `4320` is Alloy's host-mapped OTLP HTTP port from `docker-compose.yml`. The agent auto-instruments
Spring MVC, JDBC, HTTP clients (RestTemplate/WebClient) and common messaging libraries — traces show up
in Tempo with no further changes.

## 3. Logs: structured JSON with trace correlation

Add `logstash-logback-encoder` and switch `logback-spring.xml` to a JSON encoder. With
`-Dotel.instrumentation.logback-mdc.enabled=true` set above, `trace_id`/`span_id` are automatically
injected into the MDC, so they appear in every JSON log line without extra code:

```xml
<dependency>
    <groupId>net.logstash.logback</groupId>
    <artifactId>logstash-logback-encoder</artifactId>
    <version>7.4</version>
</dependency>
```

`logback-spring.xml`:

```xml
<configuration>
  <appender name="JSON" class="ch.qos.logback.core.ConsoleAppender">
    <encoder class="net.logstash.logback.encoder.LogstashEncoder" />
  </appender>
  <root level="INFO">
    <appender-ref ref="JSON" />
  </root>
</configuration>
```

## 4. Sanity check

```bash
curl http://localhost:8080/actuator/prometheus | grep http_server_requests
```

Prometheus's `java-app` job should show as UP within ~15s, and a request through the app should produce
a trace in Tempo with the same `trace_id` as the JSON log line on stdout.
