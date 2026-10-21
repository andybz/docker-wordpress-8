#!/bin/sh
# Container healthcheck: verifies nginx/php respond and runs the WP cron queue.
# Any HTTP response below 500 counts as up, so firewall plugins (e.g. NinjaFirewall)
# answering localhost with a 403 don't mark the container unhealthy.
# Cron runs regardless of the web check result.

status=0

code=$(curl -sS -o /dev/null -w '%{http_code}' http://localhost/)
if [ "$code" = "000" ] || [ "$code" -ge 500 ]; then
  echo "web check failed: HTTP $code"
  status=1
fi

case "$WP_CRON_SKIP_PLUGINS" in true|TRUE|1) SKIP_PLUGINS=--skip-plugins ;; *) SKIP_PLUGINS= ;; esac
# random delay so containers sharing the host don't all run cron at once
sleep "$(tr -dc 0-9 </dev/urandom | head -c2)"
if ! su -s /bin/sh nobody -c "wp cron event run --due-now --skip-themes $SKIP_PLUGINS --path=/usr/src/wordpress --quiet"; then
  echo "wp cron failed"
  status=1
fi

exit $status
