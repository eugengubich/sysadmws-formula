include:
  - pkg.before_deploy
  - postgresql.postgresql
  - percona.percona
  - pyenv.pyenv
  - sentry.sentry
  - php-fpm.php-fpm
  - nginx.nginx
  - app.php-fpm_apps
  - app.local
  - pkg.after_deploy
