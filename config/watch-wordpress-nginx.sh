#!/bin/sh

set -eu

config_dir=/usr/src/wordpress
config_file=nginx.conf

echo "Watching ${config_dir}/${config_file} for changes..."

# Watch the directory rather than the file because WordPress plugins commonly
# replace nginx.conf with a temporary file and rename it into place.
inotifywait --monitor --quiet \
  --include '(^|/)nginx[.]conf$' \
  --event close_write,moved_to,delete \
  --format '%f' "$config_dir" |
while IFS= read -r changed_file; do
  # Wait until no further matching events arrive for one second. This avoids
  # reloading once per event when a plugin writes or replaces the file.
  while IFS= read -r -t 1 changed_file; do
    :
  done

  # Never reload a configuration that fails validation. The existing nginx
  # workers continue serving traffic if the new configuration is invalid.
  if nginx -t; then
    echo "${config_file} changed; reloading nginx..."
    nginx -s reload
  else
    echo "${config_file} changed, but nginx configuration validation failed; keeping the current configuration."
  fi
done