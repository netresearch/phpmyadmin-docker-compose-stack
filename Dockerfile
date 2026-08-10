# syntax=docker/dockerfile:1.26
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Netresearch DTT GmbH

# phpMyAdmin php-fpm image — PHP and the phpMyAdmin sources, nothing else.
# Web serving (nginx) lives in its own container, see compose.yml. Consumers
# that already run a web server can use this image on its own.
#
# Why this image exists at all: the upstream phpmyadmin/phpmyadmin image is a
# Debian/Apache build that upstream rebuilds only when phpMyAdmin itself gets
# released. In August 2026 that meant a ten-month-old image carrying ~3400
# fixable OS CVEs. The application code is identical either way; what differs
# is how often the base underneath it is refreshed. This one rebuilds daily.
#
# Two stages:
#   1. fetcher — downloads and verifies the release tarball, strips it down
#   2. runtime — php-fpm on Alpine with the app code, runs as www-data
#
# Build args:
#   PHP_VERSION      — base PHP version (default 8.4)
#   ALPINE_VERSION   — Alpine tag for the php images (default 3.22)
#   PMA_VERSION      — phpMyAdmin release (default 5.2.3, keep in sync
#                      with .phpmyadmin-version)
#   PMA_SHA256       — checksum of that release's tarball, pinned here so a
#                      swapped download fails the build rather than shipping

ARG PHP_VERSION=8.4
ARG ALPINE_VERSION=3.24

# =====================================================================
# Stage 1: fetcher
# =====================================================================
# PHP rather than plain Alpine, because the rolling variant below runs
# Composer against the release's own manifest.
FROM php:${PHP_VERSION}-cli-alpine${ALPINE_VERSION} AS fetcher

# pipefail — surface errors in piped downloads (hadolint DL4006)
SHELL ["/bin/ash", "-o", "pipefail", "-c"]

ARG PMA_VERSION=5.2.3
ARG PMA_SHA256=57881348297c4412f86c410547cf76b4d8a236574dd2c6b7d6a2beebe7fc44e3
# ROLLING_DEPS=true refreshes phpMyAdmin's bundled PHP libraries within the
# constraints its own composer.json declares. The release tarball ships them
# frozen at release time — 5.2.3 (October 2025) carries twig 3.11.3, whose
# known issues are fixed in later 3.x. Off by default: pinned builds stay
# byte-comparable and identical to what upstream shipped.
ARG ROLLING_DEPS=false

# hadolint ignore=DL3018
RUN apk add --no-cache ca-certificates curl tar xz git unzip
COPY --from=composer:2 /usr/bin/composer /usr/bin/composer

WORKDIR /build
RUN set -eux; \
    url="https://files.phpmyadmin.net/phpMyAdmin/${PMA_VERSION}/phpMyAdmin-${PMA_VERSION}-all-languages.tar.xz"; \
    curl -fsSL -o pma.tar.xz "$url"; \
    # The checksum is an ARG, not a file fetched from the same host: a
    # compromised mirror would serve a matching .sha256 alongside a swapped
    # tarball, so verifying against the download proves nothing.
    echo "${PMA_SHA256}  pma.tar.xz" | sha256sum -c -; \
    mkdir -p /app; \
    tar -xJf pma.tar.xz -C /app --strip-components=1; \
    rm pma.tar.xz; \
    # setup/ writes config through the browser. In a container the config
    # comes from the environment, and an exposed setup script is a way in.
    rm -rf /app/setup /app/examples /app/test /app/.github; \
    find /app -name '*.md' -maxdepth 1 -delete; \
    # Where phpMyAdmin keeps its own scratch data; must exist before the
    # runtime stage chowns it.
    mkdir -p /app/tmp

WORKDIR /app
RUN set -eux; \
    if [ "${ROLLING_DEPS}" = "true" ]; then \
        # Drop the lock so Composer resolves against the ranges in
        # composer.json instead of replaying the versions frozen at release.
        rm -f composer.lock; \
        # mysqli and zip live in the runtime stage, not here, and Composer
        # refuses to resolve without them. Ignoring the platform check is
        # safe precisely because the runtime image does provide them — and
        # the final `php -l` plus the smoke test would catch it if it did not.
        COMPOSER_ALLOW_SUPERUSER=1 composer update \
            --no-dev --no-interaction --no-progress --prefer-dist --no-scripts \
            --ignore-platform-req=ext-mysqli --ignore-platform-req=ext-zip \
            --optimize-autoloader; \
        rm -rf /root/.composer /tmp/*; \
    else \
        echo "ROLLING_DEPS=false — shipping the libraries as released"; \
    fi

# =====================================================================
# Stage 2: runtime
# =====================================================================
FROM php:${PHP_VERSION}-fpm-alpine${ALPINE_VERSION} AS runtime

SHELL ["/bin/ash", "-o", "pipefail", "-c"]

ARG PMA_VERSION=5.2.3
ARG PHP_VERSION=8.4
ARG BUILD_DATE
ARG VCS_REF

LABEL org.opencontainers.image.title="phpmyadmin-php-fpm" \
      org.opencontainers.image.description="phpMyAdmin ${PMA_VERSION} on PHP ${PHP_VERSION} / Alpine — php-fpm only (use with phpmyadmin-docker-compose-stack)" \
      org.opencontainers.image.url="https://github.com/netresearch/phpmyadmin-docker-compose-stack" \
      org.opencontainers.image.source="https://github.com/netresearch/phpmyadmin-docker-compose-stack" \
      org.opencontainers.image.documentation="https://github.com/netresearch/phpmyadmin-docker-compose-stack#readme" \
      org.opencontainers.image.vendor="Netresearch DTT GmbH" \
      org.opencontainers.image.licenses="GPL-2.0-only" \
      org.opencontainers.image.version="${PMA_VERSION}" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.revision="${VCS_REF}"

# Runtime libraries stay; the -dev packages are dropped again below, so the
# compilers never reach the published layers.
# hadolint ignore=DL3018
RUN set -eux; \
    apk add --no-cache \
        bash ca-certificates tini fcgi \
        freetype libjpeg-turbo libpng libzip icu-libs \
    && apk add --no-cache --virtual .ext-build-deps \
        autoconf gcc g++ make pkgconf \
        freetype-dev libjpeg-turbo-dev libpng-dev libzip-dev icu-dev \
    && docker-php-ext-configure gd --with-freetype --with-jpeg \
    # mysqli   — the only way phpMyAdmin talks to MySQL/MariaDB
    # gd       — renders the charts in the status pages
    # zip/bz2  — import and export of compressed dumps
    # intl     — locale-aware sorting and number formatting
    # opcache  — pure throughput; phpMyAdmin is a large codebase
    && docker-php-ext-install -j"$(nproc)" \
        bz2 gd intl mysqli opcache zip \
    && apk del --no-network .ext-build-deps \
    && rm -rf /tmp/pear

# sodium backs the cookie-auth encryption. PHP ships it as a bundled
# extension, so it needs enabling rather than building.
RUN set -eux; \
    docker-php-ext-enable sodium || true; \
    php -m | grep -qi sodium

COPY --from=fetcher --chown=www-data:www-data /app /var/www/html
COPY rootfs/ /

# The entrypoint writes the runtime limits as www-data, and PHP's own conf.d
# belongs to root — for good reason. A second scan directory keeps the
# generated file out of the root-owned one.
ENV PHP_INI_SCAN_DIR=/usr/local/etc/php/conf.d:/var/www/php-conf.d

RUN set -eux; \
    chmod 0755 /usr/local/bin/entrypoint.sh; \
    # phpMyAdmin writes its templates cache below tmp/; everything else in
    # the tree is read-only for the runtime user on purpose.
    chown -R www-data:www-data /var/www/html/tmp; \
    chmod 0700 /var/www/html/tmp; \
    mkdir -p /var/www/php-conf.d; \
    chown www-data:www-data /var/www/php-conf.d; \
    # Mount point for the assets sync (see compose.yml). Docker takes the
    # ownership of a fresh named volume from the image's directory, so
    # creating it here is what lets the unprivileged user write into it.
    mkdir -p /shared-html; \
    chown www-data:www-data /shared-html; \
    php -l /var/www/html/index.php > /dev/null

WORKDIR /var/www/html
USER www-data

# php-fpm answers FastCGI on 9000; the web server that fronts it is a
# separate container (see compose.yml).
EXPOSE 9000

# cgi-fcgi speaks FastCGI directly, so the check exercises the same path a
# request takes instead of merely proving the process exists.
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD ["/bin/sh", "-c", "SCRIPT_NAME=/ping SCRIPT_FILENAME=/ping REQUEST_METHOD=GET cgi-fcgi -bind -connect 127.0.0.1:9000 | grep -q pong"]

ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/entrypoint.sh"]
CMD ["php-fpm", "--nodaemonize"]

# =====================================================================
# Stage 3: web
# =====================================================================
# The php-fpm image above answers FastCGI and serves nothing over HTTP, so
# every consumer needs a web server in front of it. Shipping that as an
# image rather than as configuration to mount means a consumer needs two
# containers and no copied files: netresearch.de would otherwise have had
# to carry nginx.conf, the template and the snippets in its own repository,
# and every later consumer another copy of the same three files.
#
# The document root is baked in from the same `fetcher` stage the runtime
# uses, so the static assets and the PHP that renders around them always
# come from one build. That is also why the two images MUST be deployed at
# the same tag: mixing them is mixing two phpMyAdmin versions.
# The unprivileged variant rather than nginx:alpine: the stock image runs
# its master process as root, which the php-fpm stage above deliberately
# does not, and SonarCloud flags it as docker:S6471. This one runs as uid
# 101 throughout, which is why the server block listens on 8080.
FROM nginxinc/nginx-unprivileged:1.29-alpine AS web

ARG PMA_VERSION=5.2.3
ARG BUILD_DATE
ARG VCS_REF

LABEL org.opencontainers.image.title="phpmyadmin-nginx" \
      org.opencontainers.image.description="nginx fronting phpmyadmin-php-fpm ${PMA_VERSION} — configuration and document root baked in; deploy at the same tag as the php-fpm image" \
      org.opencontainers.image.url="https://github.com/netresearch/phpmyadmin-docker-compose-stack" \
      org.opencontainers.image.source="https://github.com/netresearch/phpmyadmin-docker-compose-stack" \
      org.opencontainers.image.documentation="https://github.com/netresearch/phpmyadmin-docker-compose-stack#readme" \
      org.opencontainers.image.vendor="Netresearch DTT GmbH" \
      org.opencontainers.image.licenses="GPL-2.0-only" \
      org.opencontainers.image.version="${PMA_VERSION}" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.revision="${VCS_REF}"

COPY --from=fetcher /app /var/www/html
COPY config/nginx/nginx.conf /etc/nginx/nginx.conf
COPY config/nginx/templates/ /etc/nginx/templates/
COPY config/nginx/snippets/ /etc/nginx/snippets/

# Where php-fpm is reachable. The template is rendered by the nginx
# entrypoint through envsubst, so this is an ordinary environment variable
# rather than a build-time decision.
ENV PMA_FPM_UPSTREAM=app:9000

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD ["/bin/sh", "-c", "wget -q -O /dev/null http://127.0.0.1:8080/ || exit 1"]
