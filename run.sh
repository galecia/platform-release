#!/bin/bash

set -ex

export PLATFORM_HOME=/var/www/html
export PLATFORM_API_HOME=${PLATFORM_HOME}/platform

. $(dirname $0)/build_env.sh

if [[ -z "$client_tar" || -z "$api_tar" ]]; then
  echo "Missing configs!"
  exit 1
fi

if [ -z "$client_url" ]; then
  client_url="https://github.com/ushahidi/platform-client/releases/download/${client_version}/${client_tar}"
fi
if [ -z "$api_url" ]; then
  api_url="https://github.com/ushahidi/platform/releases/download/${api_version}/${api_tar}"
fi

release_target_folder=/tmp/release/ushahidi-platform-release-${release_version}

fetch() {
  if [ ! -d /tars ]; then
    mkdir /tars
  fi
  if [ ! -f /tars/$client_tar ]; then
    curl -L -o /tars/$client_tar $client_url
  fi
  if [ ! -f /tars/$api_tar ]; then
    curl -L -o /tars/$api_tar $api_url
  fi
}

gen_config_json() {
  local dir=$1
  cat > $dir/config.json <<EOF
{
"client_id": "ushahidiui",
"client_secret": "35e7f0bca957836d05ca0492211b0ac707671261",
"backend_url": "/",
"google_analytics_id": "",
"intercom_app_id": "",
"mapbox_api_key": "pk.eyJ1IjoidXNoYWhpZGkiLCJhIjoiY2lxaXRrbmF5MDdxNmZubmUyN2p6bms5biJ9.o7pmKDIN1EtwMBp1VIzITQ",
"raven_url": ""
}
EOF
}

build() {
  mkdir -p /tmp/client
  tar -C /tmp/client -xz -f /tars/$client_tar
  mkdir -p /tmp/api
  tar -C /tmp/api -xz -f /tars/$api_tar
  #
  local client_untar_path=/tmp/client/ushahidi-platform-client-bundle-${client_version}
  local api_untar_path=/tmp/api/ushahidi-platform-bundle-${api_version}
  #
  ## Untar bundles in a common folder
  mkdir -p $release_target_folder
  mv $client_untar_path ${release_target_folder}/html
  mv $api_untar_path ${release_target_folder}/html/platform
  #
  ## Configure the client to reach backend at '/platform'
  cat > ${release_target_folder}/html/config.js <<EOF
window.ushahidi = {
  backendUrl : "/"
};
EOF
  gen_config_json ${release_target_folder}/html
  #
  # Add .htaccess files for apache2 users
  cp /dist/html-htaccess ${release_target_folder}/html/.htaccess
  cp /dist/platform-htaccess ${release_target_folder}/html/platform/.htaccess
  cp /dist/platform-httpdocs-htaccess ${release_target_folder}/html/platform/httpdocs/.htaccess
  mkdir -p ${release_target_folder}/html/platform/storage/app/public
  cp /dist/platform-storage-app-public-htaccess \
    ${release_target_folder}/html/platform/storage/app/public/.htaccess
  #
  ## Additional files for the release
  cp /dist/README.release.md ${release_target_folder}
  mkdir ${release_target_folder}/dist
  cp /dist/apache-vhost.conf ${release_target_folder}/dist
  cp /dist/nginx-site.conf ${release_target_folder}/dist
  #
  ## Adjust folder permissions
  chown -R 0:0 ${release_target_folder}
  find ${release_target_folder}/html -type d -a -exec chmod 555 \{\} \;
  find ${release_target_folder}/html -type f -a -exec chmod -w \{\} \;
  ( cd ${release_target_folder}/html/platform ;
    if [ ! -d storage ]; then mkdir storage; fi;
    chmod -R 0775 storage )
}

bundle() {
  tar -C /tmp/release -cz -f /vols/out/ushahidi-platform-release-${release_version}.tar.gz ushahidi-platform-release-${release_version}
}

setup_api() {
  cat > /etc/supervisor/conf.d/api-log <<EOF
[program:tail-api]
autorestart=false
command=tail -f ${PLATFORM_API_HOME}/storage/logs/lumen.log
stdout_logfile=/dev/fd/1
stdout_logfile_maxbytes=0
stderr_logfile=/dev/fd/2
stderr_logfile_maxbytes=0
EOF
}

write_platform_env() {
  local app_key=`cat ${PLATFORM_API_HOME}/.env.app_key`
  cat > ${PLATFORM_API_HOME}/.env <<EOF
APP_ENV=${APP_ENV:-local}
APP_DEBUG=${APP_DEBUG:-false}
APP_KEY=${app_key}
APP_TIMEZONE=${APP_TIMEZONE:-UTC}

DB_CONNECTION=mysql
DB_HOST=${MYSQL_HOST:-mysql}
DB_DATABASE=${MYSQL_DATABASE:-ushahidi}
DB_USERNAME=${MYSQL_USER:-ushahidi}
DB_PASSWORD=${MYSQL_PASSWORD:-ushahidi}
DB_TYPE=MySQLi

CACHE_DRIVER=file
QUEUE_DRIVER=sync
EOF
}

run() {
  install_app
  #
  case "$SERVER_FLAVOR" in
    apache2)
      setup_apache
      ;;
    nginx)
      setup_fpm
      setup_nginx
      ;;
    *)
      echo "Unknown server flavor! $SERVER_FLAVOR"
      exit 1
      ;;
  esac
  # Setup cron and supervisor
  setup_api
  setup_cron
  setup_supervisord
  # Start supervisor
  exec supervisord -n -c /etc/supervisor/supervisord.conf
}

install_app() {
  # Install release folders in webroot
  rsync -ar --delete-after ${release_target_folder}/html/ ${PLATFORM_HOME}/
  #
  ## Configure platform environment ensure mysql connection and run migrations
  #
  # Create app_key
  if [ ! -f ${PLATFORM_API_HOME}/.env.app_key ]; then
    cat /dev/urandom | \
      LC_ALL=C tr -cd 'A-Za-z0-9_\!\@\#\$\%\^\&\*\(\)-+=' | \
      fold -w 32 | \
      head -1 \
    > ${PLATFORM_API_HOME}/.env.app_key
  fi
  #
  write_platform_env
  while ! nc -z $MYSQL_HOST 3306 ; do
    sleep 1;
  done

  ( cd ${PLATFORM_API_HOME} ;
    # Run migrations
    ./bin/phinx migrate -c phinx.php
    # Generate passport keys
    if [ ! -f storage/passport/oauth-private.key ]; then
      mkdir -p storage/passport
      php artisan passport:keys
      chmod 770 storage/passport
      chmod 660 storage/passport/*.key
    fi
    # Ensure lumen log file
    mkdir -p ${PLATFORM_API_HOME}/storage/logs
    touch ${PLATFORM_API_HOME}/storage/logs/lumen.log
    ## Adjust permissions
    chown -R www-data:www-data storage
  )


}

setup_apache() {
  # Configure apache and .htaccess
  cp /dist/apache-vhost.conf /etc/apache2/sites-available/000-default.conf
  ( cd /etc/apache2/sites-enabled ; ln -sf ../sites-available/000-default.conf . )
  ( cd /etc/apache2/mods-enabled ; ln -sf ../mods-available/rewrite.load . )
  ( cd /etc/apache2/mods-enabled ; ln -sf ../mods-available/headers.load . )
  #
  cat > /etc/supervisor/conf.d/apache2 <<EOF
[program:apache2]
autorestart=false
command=/usr/sbin/apache2ctl -DFOREGROUND
stdout_logfile=/dev/fd/1
stdout_logfile_maxbytes=0
stderr_logfile=/dev/fd/2
stderr_logfile_maxbytes=0
EOF
}

gen_fpm_www_pool_config() {
  cat <<EOF
[www]
user = www-data
group = www-data
listen = 127.0.0.1:9000
pm = dynamic
pm.max_children = 5
pm.start_servers = 2
pm.min_spare_servers = 1
pm.max_spare_servers = 3
php_admin_value[memory_limit] = 128M
EOF
}

setup_fpm() {
  mkdir /run/php
  gen_fpm_www_pool_config > ${PHP_FPM_CONFIG}/pool.d/www.conf
  cat > /etc/supervisor/conf.d/php-fpm <<EOF
[program:phpfpm]
autorestart=false
command=${PHP_FPM_PATH} -F
stdout_logfile=/dev/fd/1
stdout_logfile_maxbytes=0
stderr_logfile=/dev/fd/2
stderr_logfile_maxbytes=0

[program:tail-phpfpm]
autorestart=false
command=tail -f /var/log/php7.0-fpm.log
stdout_logfile=/dev/fd/1
stdout_logfile_maxbytes=0
stderr_logfile=/dev/fd/2
stderr_logfile_maxbytes=0
EOF
}

setup_nginx() {
  cp /dist/nginx-site.conf /etc/nginx/sites-available/default
  cat > /etc/supervisor/conf.d/nginx <<EOF
[program:nginx]
autorestart=false
command=/usr/sbin/nginx -g "daemon off;"
stdout_logfile=/dev/fd/1
stdout_logfile_maxbytes=0
stderr_logfile=/dev/fd/2
stderr_logfile_maxbytes=0
EOF
}

setup_cron() {
  ## Install crontab
  local cron_file=$(tempfile)
  touch /var/log/cronjobs.out
  chmod 777 /var/log/cronjobs.out
  cat > ${cron_file} <<EOF
PATH=/usr/local/bin:/usr/bin:/bin
SHELL=/bin/bash
*/5 * * * * cd ${PLATFORM_API_HOME} && ./artisan datasource:outgoing 2>&1 >> /var/log/cronjobs.out
*/5 * * * * cd ${PLATFORM_API_HOME} && ./artisan datasource:incoming 2>&1 >> /var/log/cronjobs.out
*/5 * * * * cd ${PLATFORM_API_HOME} && ./artisan savedsearch:sync 2>&1 >> /var/log/cronjobs.out
*/5 * * * * cd ${PLATFORM_API_HOME} && ./artisan notification:queue 2>&1 >> /var/log/cronjobs.out
*/5 * * * * cd ${PLATFORM_API_HOME} && ./artisan webhook:send 2>&1 >> /var/log/cronjobs.out
EOF
  crontab -u www-data ${cron_file}
  rm -f ${cron_file}
  #
  cat > /etc/supervisor/conf.d/cron <<EOF
[program:cron]
autorestart=false
command=cron -f

[program:tail-cron]
autorestart=false
command=tail -f /var/log/cronjobs.out
stdout_logfile=/dev/fd/1
stdout_logfile_maxbytes=0
stderr_logfile=/dev/fd/2
stderr_logfile_maxbytes=0
EOF
}

setup_supervisord() {
  cat > /etc/supervisor/supervisord.conf <<EOF
[supervisord]
nodaemon=true
logfile = /var/log/supervisord.log
logfile_maxbytes = 50MB
logfile_backups=10

[unix_http_server]
file=/var/run/supervisord.sock

[supervisorctl]
serverurl = unix:///var/run/supervisord.sock

[rpcinterface:supervisor]
supervisor.rpcinterface_factory = supervisor.rpcinterface:make_main_rpcinterface

[include]
files = conf.d/*
EOF
}

case "$1" in
  build)
    fetch
    build
    bundle
    ;;
  run)
    fetch
    build
    run
    ;;
esac
