#############################################################################
#  xiaonuo-php (PHP + FPM + Redis/Swoole/MongoDB) 多阶段构建
#  - builder(编译阶段) = iflyelf/ubuntu:latest
#      已预装 Go / Node / Python / build-essential / libssl-dev 等大部分 -dev 库,
#      仅补装 PHP 专用的 -dev 库, 构建更快更稳。
#  - runtime(运行阶段) = iflyelf/ubuntu:lite
#      仅拷贝 PHP 安装目录 + 安装运行所需的共享库, 镜像更小。
#############################################################################

# ========================= 全局版本变量(两个阶段共享) =========================
# PHP  https://github.com/php/php-src
ARG PHP_VERSION=8.5.12

# 扩展插件版本
# redis    https://pecl.php.net/package/redis
ARG REDIS_VERSION=6.3.0
# swoole   https://pecl.php.net/package/swoole
ARG SWOOLE_VERSION=6.2.5
# mongodb  https://pecl.php.net/package/mongodb
ARG MONGODB_VERSION=2.5.7

# 公共路径
ARG PHP_DIR=/data/php
ARG DOWNLOAD_SRC=/tmp/src


####################################################################
#                     构建阶段 (builder)                            #
####################################################################
FROM iflyelf/ubuntu:latest AS builder

LABEL org.opencontainers.image.authors="iflyelf" \
      org.opencontainers.image.vendor="iflyelf"

# buildx 自动注入的目标架构
ARG TARGETARCH
ARG TARGETVARIANT

# 继承全局版本变量
ARG PHP_VERSION
ARG REDIS_VERSION
ARG SWOOLE_VERSION
ARG MONGODB_VERSION
ARG PHP_DIR
ARG DOWNLOAD_SRC

ENV PHP_VERSION=$PHP_VERSION \
    REDIS_VERSION=$REDIS_VERSION \
    SWOOLE_VERSION=$SWOOLE_VERSION \
    MONGODB_VERSION=$MONGODB_VERSION \
    PHP_DIR=$PHP_DIR \
    DOWNLOAD_SRC=$DOWNLOAD_SRC

# PHP 编译参数
# 说明: PHP 8.4 起已移除 --with-imap / --with-mhash / --with-cdb / --with-mcrypt,
#       这里同步清理, 避免 configure 报 "unrecognized option"。
#       mysqlnd 自带压缩支持, 无需 --enable-mysqlnd-compression-support。
#       ctype / xml / dom / simplexml / session 等默认启用, 不显式传入
#       (避免无意义的编译参数变动导致缓存失效), 由构建末尾的 Zabbix 自检兜底验证。
#       GD 使用系统 libgd(2.3.x): Zabbix 文档指出部分语言(中文等)需 GD >= 2.3.0
#       才能避免图表文字重叠, 故用 --with-external-gd 替代 bundled GD(2.1.0)。
ARG PHP_BUILD_CONFIG="\
    --prefix=${PHP_DIR} \
    --with-config-file-path=${PHP_DIR}/etc \
    --with-config-file-scan-dir=${PHP_DIR}/etc/conf.d \
    --with-fpm-user=nginx \
    --with-fpm-group=nginx \
    --with-curl \
    --enable-gd \
    --with-external-gd \
    --with-gettext \
    --with-openssl \
    --with-external-pcre \
    --with-pgsql \
    --with-pdo-pgsql \
    --with-mysqli=mysqlnd \
    --with-pdo-mysql=mysqlnd \
    --with-sqlite3 \
    --with-pdo-sqlite \
    --with-xsl \
    --with-zlib \
    --with-bz2 \
    --with-gmp \
    --with-readline \
    --with-ldap \
    --with-tidy \
    --with-zip \
    --with-sodium \
    --with-ffi \
    --with-password-argon2 \
    --with-pear \
    --enable-fpm \
    --enable-bcmath \
    --enable-calendar \
    --enable-dba \
    --enable-exif \
    --enable-fileinfo \
    --enable-filter \
    --enable-ftp \
    --enable-intl \
    --enable-mbstring \
    --enable-mbregex \
    --enable-mysqlnd \
    --enable-pcntl \
    --enable-posix \
    --enable-session \
    --enable-shmop \
    --enable-simplexml \
    --enable-soap \
    --enable-sockets \
    --enable-sysvmsg \
    --enable-sysvsem \
    --enable-sysvshm \
    --enable-tokenizer \
    --enable-xmlreader \
    --enable-xmlwriter \
"
ENV PHP_BUILD_CONFIG=$PHP_BUILD_CONFIG

# ***** 仅补装 PHP 专用的 -dev 库 *****
# iflyelf/ubuntu:latest 已含 build-essential/autoconf/automake/libtool/pkg-config/
# libssl-dev/zlib1g-dev/libxml2-dev/libxslt1-dev/libjpeg-dev/libffi-dev 等,
# 这里只补装其缺少的部分, 避免重装庞大依赖列表。
# 运行阶段对应的非 -dev 库见 runtime 的 PHP_RUNTIME_DEPS。
ARG PHP_EXTRA_BUILD_DEPS="\
    libcurl4-openssl-dev \
    libgd-dev \
    libpng-dev \
    libwebp-dev \
    libfreetype-dev \
    libzip-dev \
    libonig-dev \
    libicu-dev \
    libreadline-dev \
    libgmp-dev \
    libbz2-dev \
    libtidy-dev \
    libpq-dev \
    libsqlite3-dev \
    libldap2-dev \
    libsasl2-dev \
    libpcre2-dev \
    libsodium-dev \
    libargon2-dev \
    libmagic-dev \
    bison \
    re2c \
    pkg-config"

RUN set -eux && \
    DEBIAN_FRONTEND=noninteractive apt update -qqy && \
    DEBIAN_FRONTEND=noninteractive apt install -qqy $PHP_EXTRA_BUILD_DEPS --option=Dpkg::Options::=--force-confdef && \
    for pkg in $PHP_EXTRA_BUILD_DEPS; do \
        if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "install ok installed"; then \
            echo "ERROR: 依赖包未成功安装: $pkg" >&2 && exit 1; \
        fi; \
    done && \
    echo "PHP 构建依赖补装完成" && \
    rm -rf /var/lib/apt/lists/*

# ***** 创建相关目录 *****
RUN set -eux && \
    mkdir -pv ${DOWNLOAD_SRC} ${PHP_DIR}

# ***** 下载源码包 *****
RUN set -eux && \
    wget --no-check-certificate https://github.com/php/php-src/archive/refs/tags/php-${PHP_VERSION}.tar.gz \
    -O ${DOWNLOAD_SRC}/php-${PHP_VERSION}.tar.gz && \
    wget --no-check-certificate https://pecl.php.net/get/redis-${REDIS_VERSION}.tgz \
    -O ${DOWNLOAD_SRC}/redis-${REDIS_VERSION}.tgz && \
    wget --no-check-certificate https://pecl.php.net/get/swoole-${SWOOLE_VERSION}.tgz \
    -O ${DOWNLOAD_SRC}/swoole-${SWOOLE_VERSION}.tgz && \
    wget --no-check-certificate https://pecl.php.net/get/mongodb-${MONGODB_VERSION}.tgz \
    -O ${DOWNLOAD_SRC}/mongodb-${MONGODB_VERSION}.tgz && \
    cd ${DOWNLOAD_SRC} && \
    tar xf php-${PHP_VERSION}.tar.gz -C ${DOWNLOAD_SRC} && \
    tar xf redis-${REDIS_VERSION}.tgz -C ${DOWNLOAD_SRC} && \
    tar xf swoole-${SWOOLE_VERSION}.tgz -C ${DOWNLOAD_SRC} && \
    tar xf mongodb-${MONGODB_VERSION}.tgz -C ${DOWNLOAD_SRC}

# ***** 编译安装 PHP + 扩展 *****
RUN set -eux && \
    cd ${DOWNLOAD_SRC}/php-src-php-${PHP_VERSION} && \
    ./buildconf --force && \
    ./configure ${PHP_BUILD_CONFIG} && \
    make -j$(($(nproc)+1)) && \
    make -j$(($(nproc)+1)) install && \
    ln -sf ${PHP_DIR}/bin/* /usr/bin/ && \
    ln -sf ${PHP_DIR}/sbin/* /usr/sbin/ && \
    for ext in redis swoole mongodb; do \
        case $ext in \
            redis)   ver=${REDIS_VERSION}   ;; \
            swoole)  ver=${SWOOLE_VERSION}  ;; \
            mongodb) ver=${MONGODB_VERSION} ;; \
        esac && \
        cd ${DOWNLOAD_SRC}/${ext}-${ver} && \
        ${PHP_DIR}/bin/phpize && \
        ./configure --with-php-config=${PHP_DIR}/bin/php-config && \
        make -j$(($(nproc)+1)) && \
        make -j$(($(nproc)+1)) install ; \
    done && \
    ${PHP_DIR}/bin/php -v && \
    ${PHP_DIR}/bin/php-config --extension-dir


####################################################################
#                     运行阶段 (runtime)                            #
####################################################################
FROM iflyelf/ubuntu:lite

LABEL org.opencontainers.image.authors="iflyelf" \
      org.opencontainers.image.vendor="iflyelf" \
      org.opencontainers.image.description="xiaonuo-php (PHP + FPM + Redis/Swoole/MongoDB), runtime on ubuntu:lite"

# 时区/语言(继承 lite 默认, 显式声明便于覆盖)
ARG TZ=Asia/Shanghai
ENV TZ=$TZ
ARG LANG=zh_CN.UTF-8
ENV LANG=$LANG

# 镜像变量
ARG DOCKER_IMAGE=iflyelf/php
ENV DOCKER_IMAGE=$DOCKER_IMAGE
ARG DOCKER_IMAGE_OS=ubuntu
ENV DOCKER_IMAGE_OS=$DOCKER_IMAGE_OS
ARG DOCKER_IMAGE_TAG=latest
ENV DOCKER_IMAGE_TAG=$DOCKER_IMAGE_TAG

# 继承路径变量
ARG PHP_DIR=/data/php
ENV PHP_DIR=$PHP_DIR
ENV PATH=${PHP_DIR}/bin:$PATH

# ***** 安装 PHP 运行所需的共享库(非 -dev 运行库) *****
# 依据编译参数精确选取运行库:
#   libxml2-16        -> libxml / dom / simplexml / xmlreader / xmlwriter
#   libcurl4t64       -> curl
#   libgd3            -> gd(外部 libgd 2.3.x, 自带 PNG/JPEG/FreeType/WebP 支持)
#   libzip5           -> zip
#   libonig5          -> mbstring
#   libicu78          -> intl
#   libreadline8t64   -> readline(CLI 交互)
#   libgmp10          -> gmp
#   libbz2-1.0        -> bz2
#   libtidy58         -> tidy
#   libpq5            -> pgsql / pdo_pgsql
#   libsqlite3-0      -> sqlite3 / pdo_sqlite
#   libldap2          -> ldap
#   libpcre2-8-0      -> PCRE2(--with-external-pcre)
#   libsodium23       -> sodium
#   libargon2-1       -> password_argon2
#   libmagic1t64      -> fileinfo
#   libxslt1.1        -> xsl
#   libstdc++6        -> swoole
#   zlib1g / ca-certificates -> 压缩与 TLS 根证书
ARG PHP_RUNTIME_DEPS="\
    libxml2-16 \
    libcurl4t64 \
    libgd3 \
    libzip5 \
    libonig5 \
    libicu78 \
    libreadline8t64 \
    libgmp10 \
    libbz2-1.0 \
    libtidy58 \
    libpq5 \
    libsqlite3-0 \
    libldap2 \
    libsasl2-2 \
    libpcre2-8-0 \
    libsodium23 \
    libargon2-1 \
    libmagic1t64 \
    libxslt1.1 \
    libstdc++6 \
    zlib1g \
    ca-certificates"

RUN set -eux && \
    DEBIAN_FRONTEND=noninteractive apt update -qqy && \
    DEBIAN_FRONTEND=noninteractive apt install -qqy --no-install-recommends $PHP_RUNTIME_DEPS --option=Dpkg::Options::=--force-confdef && \
    for pkg in $PHP_RUNTIME_DEPS; do \
        if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "install ok installed"; then \
            echo "ERROR: 运行依赖未成功安装: $pkg" >&2 && exit 1; \
        fi; \
    done && \
    echo "PHP 运行依赖验证通过" && \
    DEBIAN_FRONTEND=noninteractive apt -qqy autoremove --purge && \
    DEBIAN_FRONTEND=noninteractive apt -qqy autoclean && \
    rm -rf /var/lib/apt/lists/* /var/cache/apt/* /tmp/*

# ***** 拷贝编译产物 *****
COPY --from=builder /data/php /data/php

# ***** 拷贝配置文件 *****
COPY conf/php/etc/php.ini /data/php/etc/php.ini
COPY conf/php/etc/php-fpm.conf /data/php/etc/php-fpm.conf
COPY conf/php/etc/php-fpm.d/www.conf /data/php/etc/php-fpm.d/www.conf

# ***** 初始化: 用户/日志/扩展路径自检 *****
RUN set -eux && \
    # 创建 nginx 用户和用户组(与 nginx 镜像共用, 便于 fastcgi 联调)
    addgroup --system --quiet nginx && \
    adduser --quiet --system --disabled-login --ingroup nginx --home /data/php --no-create-home nginx && \
    # 运行目录
    mkdir -pv ${PHP_DIR}/var/run ${PHP_DIR}/var/log ${PHP_DIR}/etc/conf.d && \
    # 日志转发到 docker 日志收集器
    ln -sf /dev/stderr ${PHP_DIR}/var/log/php-fpm.log && \
    # extension_dir 自动跟随当前 PHP 版本(ZEND_MODULE_API_NO 随版本变化, 不再手工维护)
    EXT_DIR="$(${PHP_DIR}/bin/php-config --extension-dir)" && \
    sed -i "s|^extension_dir = .*|extension_dir = \"${EXT_DIR}/\"|" ${PHP_DIR}/etc/php.ini && \
    grep -E '^extension_dir' ${PHP_DIR}/etc/php.ini && \
    # 软链 php/php-fpm 到系统 PATH
    ln -sf ${PHP_DIR}/bin/* /usr/bin/ && \
    ln -sf ${PHP_DIR}/sbin/* /usr/sbin/ && \
    # smoke test: 版本 + 已加载扩展 + fpm 配置校验
    php -v && \
    php -m | grep -iE 'redis|swoole|mongodb|pgsql|pdo_mysql|pdo_pgsql|mysqli|opcache' && \
    php-fpm -t

# ***** Zabbix 前端依赖自检 *****
# 依据 https://www.zabbix.com/documentation/8.0/zh/manual/installation/requirements#frontend
# 任一必需扩展/版本不满足则构建失败, 避免 PHP 升级后静默丢失 Zabbix 依赖。
# 说明: Zabbix 8.0 支持 PHP 8.2.0 - 8.5.X, 且 < 8.5.12 存在 CVE-2026-109618/109619,
#       因此这里以 8.5.12 作为安全基线(8.6+ 自动满足)。
ARG ZABBIX_MIN_PHP=8.5.12
ARG ZABBIX_MIN_GD=2.3.0
ENV ZABBIX_MIN_PHP=$ZABBIX_MIN_PHP \
    ZABBIX_MIN_GD=$ZABBIX_MIN_GD

COPY scripts/zabbix-check.php /usr/local/bin/zabbix-check.php

RUN set -eux && \
    chmod +x /usr/local/bin/zabbix-check.php && \
    php /usr/local/bin/zabbix-check.php

# 自动检测服务是否可用(监听 9000 端口)
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s CMD ss -lnt | grep -q ':9000' || exit 1

# ***** 监听端口 *****
EXPOSE 9000/TCP

# ***** 工作目录 *****
WORKDIR /data/php

# ***** 容器信号处理 *****
STOPSIGNAL SIGQUIT

# ***** 启动命令(tini 作为 init, 优雅处理信号) *****
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["php-fpm", "--nodaemonize", "--fpm-config", "/data/php/etc/php-fpm.conf"]
