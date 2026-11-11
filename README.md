# php-docker

自研 **xiaonuo-php** 镜像：基于官方 PHP 源码编译，内置 PHP-FPM 及 Redis / Swoole / MongoDB 等常用扩展，
采用多阶段构建，运行镜像更小。

支持 `linux/amd64` 与 `linux/arm64` 多架构，标签为 `latest` 与当前 PHP 版本号（如 `8.5.12`）。

## 多阶段构建

| 阶段 | 基础镜像 | 作用 |
| --- | --- | --- |
| builder | `iflyelf/ubuntu:latest` | 已预装 Go / Node / Python / build-essential 及大部分 -dev 库，仅补装 PHP 专用的少量 -dev 库后编译，构建更快更稳 |
| runtime | `iflyelf/ubuntu:lite` | 仅拷贝 PHP 安装目录 + 安装 PHP 运行所需的共享库，镜像更小 |

运行阶段额外安装的运行库（按编译参数精确选取）：
`libxml2-16`、`libcurl4t64`、`libpng16-16t64`、`libjpeg-turbo8`、`libfreetype6`、`libwebp7`（GD）、
`libzip5`、`libonig5`（mbstring）、`libicu78`（intl）、`libreadline8t64`、`libgmp10`、`libbz2-1.0`、
`libtidy58`、`libpq5`（pgsql）、`libsqlite3-0`、`libldap2`、`libpcre2-8-0`、`libsodium23`、
`libargon2-1`、`libmagic1t64`（fileinfo）、`libxslt1.1`（xsl）、`libstdc++6`（swoole）、
`zlib1g`、`ca-certificates`。

运行阶段环境变量：`PATH` 追加 `${PHP_DIR}/bin`；入口使用 tini；`php-fpm` 日志转发到 Docker 日志收集器。

### extension_dir 自动跟随 PHP 版本

`php.ini` 中的扩展目录后缀是 PHP 的 `ZEND_MODULE_API_NO`（如 PHP 8.4 → `20240924`，PHP 8.5 → `20250925`），
会随 PHP 大版本变化。本项目通过两种方式保证其始终正确：

- **构建时**：Dockerfile 用 `php-config --extension-dir` 读取真实路径并自动写回 `php.ini`，升级 PHP 无感知；
- **定时任务**：`update-version.yml` 从 `php-src` 的 `Zend/zend_modules.h` 读取 `ZEND_MODULE_API_NO` 并同步更新仓库中的 `php.ini`。

## 镜像获取

```bash
# Docker Hub（国外）
docker pull iflyelf/php:latest

# 华为云 SWR（国内推荐）
docker pull swr.cn-east-3.myhuaweicloud.com/iflyelf/php:latest
```

## 运行

```bash
docker run -d --name php -p 9000:9000 iflyelf/php:latest
```

或使用仓库内的 `docker-compose.yml`：

```bash
docker compose up -d
```

> 该镜像只提供 PHP-FPM（监听 9000），需配合 `iflyelf/nginx` 使用，nginx 侧 `fastcgi_pass` 指向本容器 9000 端口即可。

## 内置组件

- PHP-FPM（独立编译安装，前缀 `/data/php`）
- 内置扩展（随 PHP 源码编译）：curl、gd（jpeg/webp/freetype）、mbstring、intl、opcache、sodium、
  ffi、zip、bz2、gmp、tidy、xsl、ldap、pgsql、pdo_pgsql、mysqli、pdo_mysql、pdo_sqlite、soap、
  sockets、bcmath、calendar、exif、dba、pcntl、sysvmsg/sysvsem/sysvshm、shmop、readline 等
- PECL 扩展：redis、swoole、mongodb
- 配置文件：`conf/php/etc/php.ini`、`conf/php/etc/php-fpm.conf`、`conf/php/etc/php-fpm.d/www.conf`

各组件版本见 [Dockerfile](./Dockerfile) 顶部的 `ARG` 版本变量。

> 说明：PHP 8.4 起官方已移除 `imap`、`mhash`、`cdb`、`mcrypt` 等扩展，本镜像同步移除相关编译参数。
> 如仍需 IMAP，请改用 PECL 的 `imap` 扩展单独安装。

## 自动构建

以下情况会触发 [GitHub Actions](./.github/workflows/docker-publish.yml) 构建并推送到 Docker Hub 与华为云 SWR：

- 推送 `Dockerfile`、`conf/**`、`scripts/**` 或工作流文件变更
- 手动触发（workflow_dispatch）
- Star 仓库
- 定时构建：**中国时间每天早 5 点**（UTC 21:00）

同一分支仅保留最新一次构建（`concurrency` + `cancel-in-progress`），避免多架构构建并发堆积。

### 构建前自动同步版本号

构建流程的**第一步**会执行 [scripts/update-version.sh](./scripts/update-version.sh)：
先检查并更新 `Dockerfile` 的 `PHP_VERSION` / `REDIS_VERSION` / `SWOOLE_VERSION` / `MONGODB_VERSION`
及 `php.ini` 的 `extension_dir`，如有变化则自动提交，**然后再构建**。
因此即使定时更新工作流未运行，也不会用旧版本号构建镜像。

### 版本自动更新

[update-version.yml](./.github/workflows/update-version.yml) 每天中国时间早 4 点单独执行同一份脚本：

- PHP 最新**稳定版**（php.net releases，排除 RC/beta/alpha 等，只升不降）
- PECL 扩展 redis / swoole / mongodb 最新**稳定版**
- `php.ini` 的 `extension_dir` 同步为最新 `ZEND_MODULE_API_NO`

> 该工作流只负责提交版本号；实际构建由 `docker-publish.yml` 完成，且其构建前会再次执行同一脚本，二者不会冲突。

### 构建耗时说明

- 首次全量构建（无缓存）：多架构 + arm64 QEMU 模拟，约 **2~3 小时**；
- 之后版本未变时：命中 `type=gha` 缓存，通常 **几分钟**；
- `cache-to: mode=max,ignore-error=true`：保留可复用的编译层，缓存导出失败不会中断构建；
- 任务超时保护：`timeout-minutes: 300`。

### 所需 Secrets

| Secret | 说明 |
| --- | --- |
| `DOCKER_USERNAME` / `DOCKER_PASSWORD` | Docker Hub 凭据 |
| `SWR_USERNAME` / `SWR_PASSWORD` | 华为云 SWR 登录凭据（`区域@AK` / 登录密钥） |
| `SWR_AK` / `SWR_SK` | 华为云账号 AK/SK，用于将 SWR 仓库设为公开（可选） |

## License

[MIT](./LICENSE)
