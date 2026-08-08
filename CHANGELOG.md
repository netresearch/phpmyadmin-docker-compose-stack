# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); the versions refer to
this stack, not to phpMyAdmin, whose release is recorded in
`.phpmyadmin-version`.

## [Unreleased]

### Added

- Initial release: phpMyAdmin 5.2.3 as a php-fpm image on Alpine, the nginx
  configuration in front of it, and a compose stack that runs both against
  either an existing database or a demo MariaDB.
- Optional rolling-dependency build (`ROLLING_DEPS=true`) which refreshes
  phpMyAdmin's bundled PHP libraries within its own constraints.
