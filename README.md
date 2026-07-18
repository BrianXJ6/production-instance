# Docker Production Environment

Hardened, single-container production image: **PHP 8.5 FPM on Alpine**, **Nginx** with security headers and static asset caching, and **Supervisor** running **Horizon** and the **scheduler**. Dependencies (Composer, npm) are built fresh in isolated Docker stages — never copied from the host — so the final image ships lean, with no build tooling at all.

## What's inside

| Component | Details |
| --- | --- |
| Base image | `php:8.5-fpm-alpine` |
| Web server | Nginx — security headers, gzip, long-cache for static assets, hardened `server_tokens off` |
| Process manager | Supervisor — `nginx`, `php-fpm`, `horizon`, `scheduler` |
| PHP extensions | `redis`, `imagick`, `gd` (jpeg/webp/xpm), `zip`, `pdo_mysql`, `pcntl` |
| PHP tuning | OPcache + JIT, `validate_timestamps=0`, realpath cache, secure session cookies, `display_errors=Off` |
| Runtime user | `www-data` owns the whole app tree |
| Build tooling | **Not present at runtime** — Composer/Node only exist in intermediate build stages, discarded from the final image |

## Repository layout

```text
.
├── Dockerfile          # Multi-stage: vendor (composer) → assets (npm/vite) → runtime
├── build               # Orchestrates rsync + docker build + docker save
├── .dockerignore       # Keeps stale artifacts out of the build context
├── nginx.conf          # Hardened, cache-tuned Nginx config
├── php.ini             # OPcache/JIT, secure sessions, production error handling
├── supervisord.conf    # nginx + php-fpm + horizon + scheduler
└── images/             # Exported .tar files land here (gitignored except .gitignore itself)
```

## Assumptions

Built for a standard Laravel application, expecting:

- `artisan`, `composer.json` **+ `composer.lock`**, `package.json` **+ `package-lock.json`**, and `vite.config.ts` at the project root
- **Laravel Horizon** installed (`pcntl` is compiled in — Horizon requires it). If your project doesn't use Horizon, see [Optional: plain queue worker instead of Horizon](#optional-plain-queue-worker-instead-of-horizon) below
- The scheduler runs via `schedule:work` (long-lived process — no OS cron needed)
- `.env` is **not** baked into the image (excluded on purpose) — it must be injected at deploy time (env vars, secrets manager, mounted file, etc.)

## How the build works

Two moving pieces: the `build` shell script (runs on your host/CI) and the multi-stage `Dockerfile` (runs inside Docker).

### 1. `build` — stage the source, then hand off to Docker

```bash
chmod +x docker/production/build                # once, after cloning

./docker/production/build                       # auto-named + versioned by git short SHA
./docker/production/build v2.1.0                # explicit version tag
PROJECT_NAME=myapp ./docker/production/build
```

- **`PROJECT_NAME`** — `PROJECT_NAME` env var, or the project's root folder name by default. No editing the script required to reuse it on another project.
- **`PROJECT_VERSION`** — first CLI argument, or the current git short SHA, or `latest` as a last resort.

It then `rsync`s the project into `docker/production/app/`, stripped of everything the image doesn't need:

| Excluded | Why |
| --- | --- |
| `.git`, `*.log`, `docker/`, `README.md`, `.env*` | Never needed at runtime |
| `vendor/`, `node_modules/`, `public/build/` | Rebuilt **fresh inside the image** (see below) — copying host-built artifacts in would silently break native bindings if the host's OS/arch differs from Alpine/musl |
| `storage/framework/**`, `bootstrap/cache/**` | Runtime-generated; only their `.gitignore` placeholders are kept so the directories exist |

**`composer.lock` and `package-lock.json` are intentionally *not* excluded**, even in projects that don't commit them to git — `composer install`/`npm ci` need the exact pinned versions for a reproducible build, and `npm ci` refuses to run at all without a lockfile.

Finally it runs `docker build --no-cache` and `docker save`s the result as a `.tar` under `images/` — that file is what you ship to your server / registry / CI artifact store.

### 2. `Dockerfile` — three stages

```text
┌─────────────┐   ┌─────────────┐   ┌──────────────────────┐
│   vendor    │   │   assets    │   │   runtime (final)    │
│ composer:2  │   │ node:24     │   │ php:8.5-fpm-alpine   │
│             │   │             │   │                      │
│ composer    │   │ npm ci      │   │ COPY app/            │
│ install     │   │ npm run     │   │ COPY --from=vendor   │
│ --no-dev    │   │ build       │   │ COPY --from=assets   │
└─────────────┘   └─────────────┘   └──────────────────────┘
```

- **`vendor`** — the *whole* synced app is copied in (not just `composer.json`/`lock`) because Laravel's own post-install scripts (`package:discover`, etc.) need `artisan` and the framework bootstrap present, not just the dependency manifest.
- **`assets`** — `npm ci` (requires the lockfile) then `npm run build` (Vite). Runs standalone; doesn't need PHP/Composer at all.
- **`runtime`** — starts completely fresh from `php:8.5-fpm-alpine`, copies in the app code plus the two build outputs (`vendor/`, `public/build/`) via `COPY --from=`. Composer, Node, and npm are never installed here — they simply don't exist in the shipped image.

Because `docker build --no-cache` is used on every run, there's no attempt at layer-caching optimization between stages — the priority here is a clean, reproducible build over incremental speed.

## Supervised processes

| Program | Command | Notes |
| --- | --- | --- |
| `nginx` | `nginx -g 'daemon off;'` | Port 80, `startretries=3` |
| `php-fpm` | `php-fpm --nodaemonize` | FastCGI on 127.0.0.1:9000 |
| `horizon` | `artisan horizon` | `stopwaitsecs=300` — graceful shutdown must outlast the longest job you expect to be mid-flight when a deploy/restart happens |
| `scheduler` | `artisan schedule:work` | Replaces OS cron |

All logs land in `/var/log/supervisor/*.log`.

> **`stopwaitsecs` only matters at shutdown, not during normal operation** — it's the grace period `supervisord` gives a process to finish its current job after receiving `SIGTERM` (deploy, restart, host reboot — not just crashes) before force-killing it with `SIGKILL`. Size it to your slowest job, with margin. And make sure your orchestrator's own stop timeout (`docker stop -t`, `stop_grace_period` in Compose, a Kubernetes `terminationGracePeriodSeconds`, …) is set **at least as high** — otherwise the outer timeout kills the whole container before `supervisord`'s own grace period has a chance to work.

## Nginx hardening highlights

- `server_tokens off` — doesn't leak the Nginx version
- Security headers on every response: `X-Frame-Options`, `X-Content-Type-Options`, `Referrer-Policy`, `Permissions-Policy`
- `.css`/`.js` cached 1 year immutable; images/fonts cached 6 months — Vite's content-hashed filenames make this safe
- Add HSTS (`Strict-Transport-Security`) at your edge/CDN (e.g. Cloudflare) instead of here, if you terminate TLS in front of this container

## PHP configuration highlights

- `display_errors=Off`, errors logged instead — never leak stack traces to users
- **OPcache with JIT** (`tracing` mode, 64M buffer), `validate_timestamps=0` — the filesystem is never re-checked for changes; **you must restart `php-fpm` after every deploy** for new code to take effect (a fresh container image already does this naturally)
- Secure session cookies: `session.cookie_secure=1`, `httponly=1`, `samesite=Lax`
- Realpath cache tuned to cut filesystem stat() calls

## Testing the image locally

Before shipping anywhere, run the same smoke test used to validate this setup:

```bash
docker load -i docker/production/images/<name>-<version>.tar

docker run -d --name app-smoketest \
  --network <your-network> \
  -e APP_KEY="base64:...." \
  -e DB_HOST=mysql -e DB_DATABASE=... -e DB_USERNAME=... -e DB_PASSWORD=... \
  -e REDIS_HOST=redis \
  -e APP_ENV=production -e APP_DEBUG=false \
  -p 8099:80 \
  <name>:<version>

docker exec app-smoketest ps aux           # nginx, php-fpm, horizon, scheduler all up?
curl -I http://localhost:8099/             # 200 with the app's real headers?

docker rm -f app-smoketest
```

## Optional: plain queue worker instead of Horizon

If your project doesn't use Horizon, drop the `[program:horizon]` block from `supervisord.conf` and use plain `queue:work` instead:

```ini
[program:queue-worker]
autostart=true
autorestart=true
stopwaitsecs=150
command=/usr/local/bin/php /var/www/artisan queue:work --sleep=3 --tries=3 --max-time=3600
stderr_logfile=/var/log/supervisor/queue-worker.err.log
stdout_logfile=/var/log/supervisor/queue-worker.out.log
```

`pcntl` is still worth keeping even without Horizon — it's what lets `queue:work` catch `SIGTERM` and finish its current job gracefully instead of dying mid-execution. Only add `numprocs`/`process_name` (multiple workers) or `stopasgroup`/`killasgroup` (jobs that spawn subprocesses) if you actually need them — they're not required for a single, direct `queue:work` process.

## Tips & known quirks

- **The exported `.tar` files in `images/` are large** (roughly the size of the final image) — `.dockerignore` already excludes them from being re-uploaded as build context on the next run, but don't commit them to git.
- **`--no-cache` on every build** means every run reinstalls Composer/npm dependencies from scratch — slower, but guarantees nothing stale leaks between builds. If build time becomes a problem, revisit this deliberately (e.g., BuildKit cache mounts) rather than silently dropping it.
- **`.env` is never in the image, by design** — inject configuration at deploy time. Don't "fix" a missing-env error by copying `.env` into the Dockerfile.
- **After any deploy**, `horizon:terminate` (or an equivalent for a plain queue worker) may still be worth running explicitly if you're doing a rolling/in-place update rather than a full container replacement — long-lived worker processes hold old code in memory otherwise.
