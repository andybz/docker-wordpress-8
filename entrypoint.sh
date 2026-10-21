#! /bin/bash

# terminate on errors
# set -e

# Function to check for and import SQL file if the database is empty
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
        fi
      else
        echo "Database already contains tables. Skipping SQL import."
      fi
    else
      echo "Failed to connect to database. SQL import will be skipped."
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

# good default wp config settings
if [[ ! -f "/usr/src/wordpress/.wp-config-configured" ]]; then
  # update database connection settings if environment variables are set
  if [[ ! -z "$DB_HOST" ]]; then
    echo "Updating database host from environment variable..."
    wp --path=/usr/src/wordpress config set DB_HOST "$DB_HOST" --skip-themes --skip-plugins
  fi
  if [[ ! -z "$DB_NAME" ]]; then
    echo "Updating database host from environment variable..."
    wp --path=/usr/src/wordpress config set DB_NAME "$DB_NAME" --skip-themes --skip-plugins
  fi
  if [[ ! -z "$MDBU" ]]; then
    echo "Updating database user from environment variable..."
    wp --path=/usr/src/wordpress config set DB_USER "$MDBU" --skip-themes --skip-plugins
  fi
  if [ $? -eq 0 ]; then
    if [[ ! -z "$MDBP" ]]; then
      echo "Updating database password from environment variable..."
      wp --path=/usr/src/wordpress config set DB_PASSWORD "$MDBP" --skip-themes --skip-plugins
    fi

    # Set each WordPress configuration option individually
    echo "Setting WordPress configuration options..."
    wp --path=/usr/src/wordpress config set DISABLE_WP_CRON true --raw --skip-themes --skip-plugins
    wp --path=/usr/src/wordpress config set WP_POST_REVISIONS 5 --raw --skip-themes --skip-plugins

    # Shuffle salts (can't do this bc it will nuke stuff in fluent smtp and other plugins :()
    # wp --path=/usr/src/wordpress config shuffle-salts --skip-themes --skip-plugins

    # Remove w3 master.php
    rm -f /usr/src/wordpress/wp-content/w3tc-config/master.php

    # Try to import SQL if database is empty
    import_sql_if_needed

    # add file to prevent this from running again only if commands were successful
    touch /usr/src/wordpress/.wp-config-configured
    echo "WordPress configuration completed successfully."
  else
    echo "Failed to set WordPress configuration options."
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
  wp --path=/usr/src/wordpress plugin --skip-themes install --activate "${PLUGINS_TO_INSTALL[@]}"
fi

# auto setup w3 total cache
if [[ ! -f "/usr/src/wordpress/.w3tc-configured" ]]; then
  if wp --path=/usr/src/wordpress plugin --skip-themes is-active litespeed-cache; then
    wp --path=/usr/src/wordpress plugin --skip-themes --uninstall deactivate litespeed-cache
  fi
  if [ ! "$(ls -A "/usr/src/wordpress/wp-content/plugins/w3-total-cache" 2>/dev/null)" ]; then
    wp --path=/usr/src/wordpress plugin --skip-themes install --activate w3-total-cache
  fi
  echo "Updating cache options..."
  wp --path=/usr/src/wordpress --skip-themes w3-total-cache option set pgcache.engine "file_generic"
  wp --path=/usr/src/wordpress --skip-themes w3-total-cache option set dbcache.engine "apc"
  wp --path=/usr/src/wordpress --skip-themes w3-total-cache option set objectcache.engine "apc"

  if [ "$REDIS_HOST" ]; then
    wp --path=/usr/src/wordpress --skip-themes w3-total-cache option set dbcache.redis.servers "$REDIS_HOST" --type=array
    wp --path=/usr/src/wordpress --skip-themes w3-total-cache option set objectcache.redis.servers "$REDIS_HOST" --type=array
    wp --path=/usr/src/wordpress --skip-themes w3-total-cache option set pgcache.redis.servers "$REDIS_HOST" --type=array
  fi

  wp --path=/usr/src/wordpress --skip-themes w3-total-cache option set dbcache.enabled true --type=boolean
  wp --path=/usr/src/wordpress --skip-themes w3-total-cache option set objectcache.enabled true --type=boolean
  wp --path=/usr/src/wordpress --skip-themes w3-total-cache option set pgcache.enabled true --type=boolean
  wp --path=/usr/src/wordpress --skip-themes w3-total-cache option set browsercache.enabled true --type=boolean
  wp --path=/usr/src/wordpress --skip-themes w3-total-cache option set browsercache.html.expires true --type=boolean
  wp --path=/usr/src/wordpress --skip-themes w3-total-cache option set browsercache.html.cache.control true --type=boolean

  wp --path=/usr/src/wordpress --skip-themes w3-total-cache option set pgcache.lifetime 186400 --type=integer
  wp --path=/usr/src/wordpress --skip-themes w3-total-cache option set browsercache.html.lifetime 180 --type=integer

  wp --path=/usr/src/wordpress --skip-themes w3-total-cache fix_environment nginx

  # add file to prevent this from running again
  touch /usr/src/wordpress/.w3tc-configured
  touch /usr/src/wordpress/.w3tc-reconfigured
  # fix permissions
  chown -R nobody: /usr/src/wordpress/
fi

# Reconfigure w3 total cache if it is active and not on current config
if [[ ! -f "/usr/src/wordpress/.w3tc-reconfigured" ]] && wp --path=/usr/src/wordpress plugin --skip-themes is-active w3-total-cache; then
  echo "Reconfiguring cache options..."
  wp --path=/usr/src/wordpress --skip-themes w3-total-cache option set pgcache.engine "file_generic"
  wp --path=/usr/src/wordpress --skip-themes w3-total-cache option set dbcache.engine "apc"
  wp --path=/usr/src/wordpress --skip-themes w3-total-cache option set objectcache.engine "apc"
  wp --path=/usr/src/wordpress --skip-themes w3-total-cache fix_environment nginx
  mkdir -p /usr/src/wordpress/wp-content/cache/page_enhanced && chown -R nobody: /usr/src/wordpress/wp-content/cache/
  touch /usr/src/wordpress/.w3tc-reconfigured
fi

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
