#! /bin/bash

# terminate on errors
# set -e

# Run a command as nobody (the PHP-FPM user), like config/healthcheck.sh does.
as_nobody() {
  # "--" stops busybox su from parsing the command's own --options
  su -s /bin/sh -c 'exec "$@"' -- nobody as_nobody "$@"
}

# wp-cli refuses to run as root when PHP has the posix extension (the official
# php image does), and --allow-root would run plugin code as root.
export WP_CLI_CACHE_DIR=/tmp/wp-cli-cache
wp() {
  as_nobody wp "$@"
}

# W3TC run from wp-cli writes the full home URL into try_files
# (https://example.com/index.php?$args), so virtual .xml/.txt URLs like sitemaps 404.
fix_w3tc_nginx_conf() {
  NGINX_CONF=/usr/src/wordpress/nginx.conf
  if [[ -f "$NGINX_CONF" ]] && grep -Eq 'try_files.*https?://[^/ ]+/index\.php' "$NGINX_CONF"; then
    echo "Fixing full-URL try_files in nginx.conf..."
    sed -i -E '/try_files/ s#https?://[^/ ]+/index\.php#/index.php#g' "$NGINX_CONF"
    chown nobody: "$NGINX_CONF"
  fi
}

# Function to check for and import SQL file if the database is empty
# returns non-zero if a SQL file exists but could not be imported
import_sql_if_needed() {
  echo "Checking for SQL file to import..."
  # Look for any .sql file in the WordPress directory
  SQL_FILES=(/usr/src/wordpress/*.sql)

  if [ ${#SQL_FILES[@]} -gt 0 ] && [ -f "${SQL_FILES[0]}" ]; then
    SQL_FILE="${SQL_FILES[0]}"
    echo "Found SQL file: $SQL_FILE. Testing database connection..."
    # wp cli cache clear --path=/usr/src/wordpress --skip-themes --skip-plugins
    sleep 3 # wait to make sure database is ready
    if wp db check --path=/usr/src/wordpress --skip-themes --skip-plugins &>/dev/null; then
      # Check if database is empty (no tables)
      TABLES=$(wp db tables --all-tables-with-prefix --path=/usr/src/wordpress --skip-themes --skip-plugins 2>/dev/null)
      if [ -z "$TABLES" ]; then
        echo "Database is empty. Importing SQL file..."
        if wp db import "$SQL_FILE" --path=/usr/src/wordpress --skip-themes --skip-plugins; then
          rm "$SQL_FILE"
          echo "SQL file imported successfully."
        else
          echo "Failed to import SQL file. Please check SQL file format."
          return 1
        fi
      else
        echo "Database already contains tables. Skipping SQL import."
      fi
    else
      echo "Failed to connect to database. SQL import will be skipped."
      return 1
    fi
  else
    echo "No SQL file found in /usr/src/wordpress. Skipping import."
  fi
}

# install wordpress if necessary
CONFIG=/usr/src/wordpress/wp-config.php
SAMPLE=/usr/src/wordpress/wp-config-sample.php

if [ "$(ls -A /usr/src/wordpress)" ]; then
  echo "Wordpress folder is not empty. Skipping install..."
else
  echo "Wordpress files do not exist. Installing..."
  if [[ ! -f "$SAMPLE" ]]; then
    # download & extract wordpress
    curl -sO https://wordpress.org/latest.tar.gz &&
      tar -xzkf latest.tar.gz -C /usr/src/ &&
      rm latest.tar.gz &&
      chown -R nobody: /usr/src/wordpress
  fi
  # echo "*** Please restart container after Wordpress setup ***"
  # exec "$@"
fi

# exit if no wp-config.php
if [[ ! -f "$CONFIG" ]]; then
  echo "*** Config file not found. Please restart after installing Wordpress. ***"
  exec "$@"
fi

# wp-cli runs as nobody, so it needs to own wp-config.php and wp-content
# (uploaded files are often owned by the host user)
if [[ ! -f "/usr/src/wordpress/.wp-config-configured" || ! -f "/usr/src/wordpress/.w3tc-configured" ]]; then
  chown -R nobody: /usr/src/wordpress/
fi

# good default wp config settings
if [[ ! -f "/usr/src/wordpress/.wp-config-configured" ]]; then
  CONFIG_OK=true
  # update database connection settings if environment variables are set
  if [[ ! -z "$DB_HOST" ]]; then
    echo "Updating database host from environment variable..."
    wp --path=/usr/src/wordpress config set DB_HOST "$DB_HOST" --skip-themes --skip-plugins || CONFIG_OK=false
  fi
  if [[ ! -z "$DB_NAME" ]]; then
    echo "Updating database name from environment variable..."
    wp --path=/usr/src/wordpress config set DB_NAME "$DB_NAME" --skip-themes --skip-plugins || CONFIG_OK=false
  fi
  if [[ ! -z "$MDBU" ]]; then
    echo "Updating database user from environment variable..."
    wp --path=/usr/src/wordpress config set DB_USER "$MDBU" --skip-themes --skip-plugins || CONFIG_OK=false
  fi
  if [[ ! -z "$MDBP" ]]; then
    echo "Updating database password from environment variable..."
    wp --path=/usr/src/wordpress config set DB_PASSWORD "$MDBP" --skip-themes --skip-plugins || CONFIG_OK=false
  fi

  # Set each WordPress configuration option individually
  echo "Setting WordPress configuration options..."
  wp --path=/usr/src/wordpress config set DISABLE_WP_CRON true --raw --skip-themes --skip-plugins || CONFIG_OK=false
  wp --path=/usr/src/wordpress config set WP_POST_REVISIONS 5 --raw --skip-themes --skip-plugins || CONFIG_OK=false

  # Shuffle salts (can't do this bc it will nuke stuff in fluent smtp and other plugins :()
  # wp --path=/usr/src/wordpress config shuffle-salts --skip-themes --skip-plugins

  # Remove w3 master.php
  rm -f /usr/src/wordpress/wp-content/w3tc-config/master.php

  # Try to import SQL if database is empty
  import_sql_if_needed || CONFIG_OK=false

  # add file to prevent this from running again only if commands were successful
  if $CONFIG_OK; then
    touch /usr/src/wordpress/.wp-config-configured
    echo "WordPress configuration completed successfully."
  else
    echo "Failed to set WordPress configuration options. Will retry on next start."
  fi
fi

# Plugin installation
# First check which plugins need to be installed
PLUGINS_TO_INSTALL=()

# Check vips image editor
if [ ! "$(ls -A "/usr/src/wordpress/wp-content/plugins/vips-image-editor" 2>/dev/null)" ]; then
  echo 'Adding plugin: vips-image-editor'
  PLUGINS_TO_INSTALL+=("https://github.com/henrygd/vips-image-editor/releases/latest/download/vips-image-editor.zip")
fi

# Check additional plugins from environment variable
for PLUGIN in $ADDITIONAL_PLUGINS; do
  if [ ! "$(ls -A "/usr/src/wordpress/wp-content/plugins/$PLUGIN" 2>/dev/null)" ]; then
    echo "Adding plugin: $PLUGIN"
    PLUGINS_TO_INSTALL+=("$PLUGIN")
  fi
done

# sleep 3
# Install all plugins in a single command if there are any to install
if [ ${#PLUGINS_TO_INSTALL[@]} -gt 0 ]; then
  echo "Installing plugins: ${PLUGINS_TO_INSTALL[*]}"
  wp --path=/usr/src/wordpress plugin --skip-themes install --activate "${PLUGINS_TO_INSTALL[@]}" ||
    echo "Failed to install plugins. Will retry on next start."
fi

w3tc_set() {
  wp --path=/usr/src/wordpress --skip-themes w3-total-cache option set "$@" || W3TC_OK=false
}

# fix_environment exits non-zero on sites still using "Plain" permalinks but writes
# nginx.conf anyway, so only a missing nginx.conf counts as a failure
w3tc_fix_environment() {
  wp --path=/usr/src/wordpress --skip-themes w3-total-cache fix_environment nginx ||
    echo "W3 Total Cache reported a problem with the environment (see above)."
  [[ -f /usr/src/wordpress/nginx.conf ]] || W3TC_OK=false
  fix_w3tc_nginx_conf
}

# auto setup w3 total cache (needs the wp config/database step above to have worked,
# otherwise a later retry of that step would delete master.php again)
if [[ ! -f "/usr/src/wordpress/.w3tc-configured" && -f "/usr/src/wordpress/.wp-config-configured" ]]; then
  W3TC_OK=true
  if wp --path=/usr/src/wordpress plugin --skip-themes is-active litespeed-cache; then
    wp --path=/usr/src/wordpress plugin --skip-themes --uninstall deactivate litespeed-cache
  fi
  if [ ! "$(ls -A "/usr/src/wordpress/wp-content/plugins/w3-total-cache" 2>/dev/null)" ]; then
    wp --path=/usr/src/wordpress plugin --skip-themes install --activate w3-total-cache || W3TC_OK=false
  fi
  echo "Updating cache options..."
  w3tc_set pgcache.engine "file_generic"
  w3tc_set dbcache.engine "apc"
  w3tc_set objectcache.engine "apc"

  if [ "$REDIS_HOST" ]; then
    w3tc_set dbcache.redis.servers "$REDIS_HOST" --type=array
    w3tc_set objectcache.redis.servers "$REDIS_HOST" --type=array
    w3tc_set pgcache.redis.servers "$REDIS_HOST" --type=array
  fi

  w3tc_set dbcache.enabled true --type=boolean
  w3tc_set objectcache.enabled true --type=boolean
  w3tc_set pgcache.enabled true --type=boolean
  w3tc_set browsercache.enabled true --type=boolean
  w3tc_set browsercache.html.expires true --type=boolean
  w3tc_set browsercache.html.cache.control true --type=boolean

  w3tc_set pgcache.lifetime 186400 --type=integer
  w3tc_set browsercache.html.lifetime 180 --type=integer

  w3tc_fix_environment

  # add file to prevent this from running again
  if $W3TC_OK; then
    touch /usr/src/wordpress/.w3tc-configured
    touch /usr/src/wordpress/.w3tc-reconfigured
  else
    echo "Failed to configure W3 Total Cache. Will retry on next start."
  fi
  # fix permissions
  chown -R nobody: /usr/src/wordpress/
fi

# Reconfigure w3 total cache if it is active and not on current config
if [[ ! -f "/usr/src/wordpress/.w3tc-reconfigured" ]] && wp --path=/usr/src/wordpress plugin --skip-themes is-active w3-total-cache; then
  echo "Reconfiguring cache options..."
  W3TC_OK=true
  w3tc_set pgcache.engine "file_generic"
  w3tc_set dbcache.engine "apc"
  w3tc_set objectcache.engine "apc"
  w3tc_fix_environment
  mkdir -p /usr/src/wordpress/wp-content/cache/page_enhanced && chown -R nobody: /usr/src/wordpress/wp-content/cache/
  if $W3TC_OK; then
    touch /usr/src/wordpress/.w3tc-reconfigured
  fi
fi

# repair rules written by earlier versions of this script
fix_w3tc_nginx_conf

# handle cron
if [ -z "$CRON" ]; then
  echo "No cron commands specified..."
else
  # add commands
  echo "$CRON" >/tmp/newcron
  crontab /tmp/newcron
  rm /tmp/newcron

  echo "Starting cron daemon..."
  /usr/sbin/crond
fi

# make sure plugins have correct permissions
# chown -R nobody: /usr/src/wordpress/wp-content

# set file for syslog
syslogd -O /var/log/messages -s 0

exec "$@"
