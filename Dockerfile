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
  mysql-client \
  nginx \
  supervisor \
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

RUN mkdir -p /usr/src/wordpress && chown -R nobody: /usr/src/wordpress
WORKDIR /usr/src

# Add WP CLI
RUN curl -o /usr/local/bin/wp https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar \
  && chmod +x /usr/local/bin/wp

# Entrypoint to install plugins
COPY entrypoint.sh /entrypoint.sh
ENTRYPOINT [ "/entrypoint.sh" ]

EXPOSE 80

CMD ["/usr/bin/supervisord", "-c", "/etc/supervisor/conf.d/supervisord.conf"]

# healthcheck runs cron queue every 5 mintes - add disable_cron to wp-config
HEALTHCHECK --interval=300s CMD su -s /bin/sh nobody -c "cd /usr/src/wordpress/ && wp cron event run --due-now --skip-themes --skip-plugins || exit 1"
