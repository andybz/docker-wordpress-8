FROM alpine:3.23

# Install packages
RUN apk --no-cache add \
  php83 \
  php83-fpm \
  php83-mysqli \
  php83-json \
  php83-openssl \
  php83-curl \
  php83-zlib \
  php83-xml \
  php83-phar \
  php83-intl \
  php83-dom \
  php83-xmlreader \
  php83-xmlwriter \
  php83-exif \
  php83-fileinfo \
  php83-sodium \
  php83-simplexml \
  php83-ctype \
  php83-mbstring \
  php83-zip \
  php83-opcache \
  php83-iconv \
  php83-pecl-imagick \
  php83-pecl-vips \
  php83-session \
  php83-tokenizer \
  php83-gd \
  php83-pecl-redis \
  php83-soap \
  php83-pdo \
  php83-sqlite3 \
  php83-pecl-apcu \
  mariadb-client \
  nginx \
  supervisor \
  inotify-tools \
  curl \
  bash \
  less \
  tzdata \
  ca-certificates

# Create symlink so programs depending on `php` still function
RUN ln -s /usr/bin/php83 /usr/bin/php

# Configure nginx
COPY config/nginx.conf /etc/nginx/nginx.conf

# Configure PHP-FPM
COPY config/fpm-pool.conf /etc/php83/php-fpm.d/zzz_custom.conf
COPY config/php.ini /etc/php83/conf.d/zzz_custom.ini

# Configure supervisord
COPY config/supervisord.conf /etc/supervisor/conf.d/supervisord.conf

RUN mkdir -p /usr/src/wordpress /var/log/nginx /var/log/php83 && chown -R nobody: /usr/src/wordpress /var/log/nginx /var/log/php83
WORKDIR /usr/src/wordpress

# Add WP CLI
RUN curl -o /usr/local/bin/wp https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar && chmod +x /usr/local/bin/wp

# Nginx restart watcher
COPY config/watch-wordpress-nginx.sh /usr/local/bin/watch-wordpress-nginx
RUN chmod +x /usr/local/bin/watch-wordpress-nginx

# Entrypoint to install plugins
COPY entrypoint.sh /entrypoint.sh
ENTRYPOINT [ "/entrypoint.sh" ]

EXPOSE 80

CMD ["/usr/bin/supervisord", "-c", "/etc/supervisor/conf.d/supervisord.conf"]

# healthcheck runs cron queue every 5 mintes - add disable_cron to wp-config
# plugins are loaded unless WP_CRON_SKIP_PLUGINS is set to true or 1
HEALTHCHECK --interval=300s --timeout=120s CMD curl -fsS http://localhost/ >/dev/null && \
  case "$WP_CRON_SKIP_PLUGINS" in true|TRUE|1) SKIP_PLUGINS=--skip-plugins ;; *) SKIP_PLUGINS= ;; esac && \
  su -s /bin/sh nobody -c "sleep $(tr -dc 0-9 </dev/urandom | head -c2) && wp cron event run --due-now --skip-themes $SKIP_PLUGINS --path=/usr/src/wordpress --quiet" || exit 1
