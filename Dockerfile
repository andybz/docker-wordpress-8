# Official PHP image: built from php.net sources, so PHP security releases land
# within hours instead of waiting for Alpine's php83 packages.
FROM php:8.3-fpm-alpine

# PHP extensions (the official image already includes ctype, curl, dom, fileinfo,
# iconv, mbstring, openssl, pdo, session, simplexml, sodium, tokenizer, xml*, zlib)
ADD --chmod=0755 https://github.com/mlocati/docker-php-extension-installer/releases/download/2.12.0/install-php-extensions /usr/local/bin/
RUN install-php-extensions \
  apcu \
  exif \
  gd \
  igbinary \
  imagick \
  intl \
  msgpack \
  mysqli \
  opcache \
  redis \
  soap \
  sockets \
  vips \
  zip

# Install packages
RUN apk --no-cache add \
  mariadb-client \
  nginx \
  supervisor \
  inotify-tools \
  curl \
  bash \
  less \
  tzdata \
  ca-certificates

# Production php.ini defaults (matches what Alpine's php83 package shipped)
RUN cp /usr/local/etc/php/php.ini-production /usr/local/etc/php/php.ini

# Keep the old Alpine package paths working for scripts and CRON entries
RUN ln -s /usr/local/bin/php /usr/bin/php && ln -s /usr/local/bin/php /usr/bin/php83

# Configure nginx
COPY config/nginx.conf /etc/nginx/nginx.conf

# Configure PHP-FPM
COPY config/fpm-pool.conf /usr/local/etc/php-fpm.d/zzz_custom.conf
COPY config/php.ini /usr/local/etc/php/conf.d/zzz_custom.ini

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

# supervisord is PID 1; the php base image defaults to SIGQUIT for bare php-fpm
STOPSIGNAL SIGTERM

CMD ["/usr/bin/supervisord", "-c", "/etc/supervisor/conf.d/supervisord.conf"]

# healthcheck runs cron queue every 5 mintes - add disable_cron to wp-config
# plugins are loaded unless WP_CRON_SKIP_PLUGINS is set to true or 1
COPY config/healthcheck.sh /usr/local/bin/healthcheck
RUN chmod +x /usr/local/bin/healthcheck
HEALTHCHECK --interval=300s --timeout=120s CMD /usr/local/bin/healthcheck
