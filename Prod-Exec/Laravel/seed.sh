#!/bin/sh
trap 'unset APP_ENV; php artisan config:clear >/dev/null 2>&1; php artisan config:cache >/dev/null 2>&1; echo ""; echo "=========================================="; echo "Reverted to production."; php artisan env; echo "=========================================="' EXIT INT TERM

export APP_ENV=local
php artisan config:clear >/dev/null 2>&1

echo "=========================================="
echo "Environment switched to LOCAL"
php artisan env
echo "=========================================="
echo "Paste your command(s) below."
echo "Type 'done' on a new line when finished."
echo "=========================================="

while true; do
    printf "local$ "
    read -r CMD
    [ "$CMD" = "done" ] && break
    [ "$CMD" = "exit" ] && break
    [ -z "$CMD" ] && continue
    eval "$CMD"
done
