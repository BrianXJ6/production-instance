# syntax=docker/dockerfile:1
#
# Multi-stage build. The `build` script (see README.md) rsyncs the project
# into ./app before this file runs, already stripped of dev-only files
# (.git, node_modules, vendor, public/build, .env, docker/...). The two
# stages below build fresh PHP and frontend dependencies *inside* this
# image's own musl/Alpine + Node runtime — never copying host-built
# artifacts, which could target the wrong OS/arch entirely.

# ---- Stage: PHP dependencies ----
FROM composer:2 AS vendor
WORKDIR /app
# The full app (not just composer.json/lock) is needed here: Laravel's own
# post-install scripts (package:discover, etc.) require artisan and the
# framework bootstrap to be present, not just the dependency manifest.
COPY app/ .
RUN composer install \
    --no-dev \
    --no-interaction \
    --no-progress \
    --optimize-autoloader \
    --ignore-platform-reqs

# ---- Stage: Frontend build ----
FROM node:24-alpine AS assets
WORKDIR /app
COPY app/ .
RUN npm ci --no-audit --no-fund && npm run build

# ---- Stage: Production runtime ----
FROM php:8.5-fpm-alpine

WORKDIR /var/www

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=America/Recife

# Installing essential packages (runtime only — no Node/npm/Composer here;
# dependencies were already built in the stages above)
RUN apk update && apk upgrade && apk add --no-cache zlib libpng libzip imagemagick ffmpeg \
    librsvg libwebp libxpm libjpeg-turbo tzdata nginx supervisor vim zip unzip

# Configuring Timezone
RUN ln -snf /usr/share/zoneinfo/$TZ /etc/localtime

# Installation of tools and temporary packages just for build
RUN apk add --no-cache --virtual .temp-deps $PHPIZE_DEPS zlib-dev libpng-dev libzip-dev \
    imagemagick-dev ffmpeg-dev librsvg-dev libwebp-dev libxpm-dev libjpeg-turbo-dev

# Installing and enabling PHP extensions
RUN pecl install redis imagick && \
    docker-php-ext-configure gd --with-jpeg --with-webp --with-xpm && \
    docker-php-ext-install gd zip pdo_mysql pcntl && \
    docker-php-ext-enable redis imagick

# Copying and using php.ini optimized for production
RUN cp "$PHP_INI_DIR/php.ini-production" "$PHP_INI_DIR/php.ini"

# Application code (already filtered by the `build` script's rsync)
COPY app/ /var/www/

# Pre-built dependencies from the stages above
COPY --from=vendor /app/vendor /var/www/vendor
COPY --from=assets /app/public/build /var/www/public/build

# Section for copying extra configuration files and directories
COPY nginx.conf /etc/nginx/nginx.conf
COPY php.ini /usr/local/etc/php/conf.d/99-custom.ini
COPY supervisord.conf /etc/supervisor/conf.d/supervisord.conf

# Fine adjustments for proper functioning in a production environment
RUN mkdir -p /var/log/supervisor && \
    chown -R www-data:www-data /var/www && \
    chmod -R 755 /var/www/storage && \
    chmod 644 /etc/nginx/nginx.conf

# Cleaning up the image
RUN apk del .temp-deps

EXPOSE 80

ENTRYPOINT ["/usr/bin/supervisord", "-c", "/etc/supervisor/conf.d/supervisord.conf"]
