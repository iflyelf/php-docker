#!/usr/bin/env bash
#=================================================
# https://github.com/iflyelf/php-docker
# 同步 PHP / PECL 扩展版本号, 并同步 php.ini 的 extension_dir
#
# 用法:
#   bash scripts/update-version.sh
#
# 在 GitHub Actions 中会额外写入 $GITHUB_ENV:
#   CHANGED=0|1        是否有改动
#   SUMMARY=...        改动摘要(用于 commit message)
#=================================================
set -euo pipefail

DOCKERFILE="${DOCKERFILE:-Dockerfile}"
PHP_INI="${PHP_INI:-conf/php/etc/php.ini}"

# ---------- 稳定版过滤: 排除 rc/beta/alpha/test/dev/preview/snapshot ----------
is_stable() {
    echo "$1" | grep -qivE '(rc|beta|alpha|test|dev|preview|snapshot|nightly|-pre|m[0-9])'
}

# ---------- 语义化版本比较: 若 $1 > $2 返回 0 ----------
version_gt() {
    [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" = "$1" ]
}

# ---------- 取 PHP 官方最新稳定版(php.net releases JSON, 返回各主版本最新版, 取最高者) ----------
php_latest() {
    { curl -fsSL 'https://www.php.net/releases/index.php?json=1' 2>/dev/null || true; } \
        | { jq -r '.[].source[]?.filename' 2>/dev/null || true; } \
        | grep -oE '^php-[0-9]+\.[0-9]+\.[0-9]+\.tar\.gz$' \
        | sed -E 's/^php-([0-9.]+)\.tar\.gz$/\1/' \
        | sort -V | tail -1 || true
}

# ---------- 取 PECL 扩展最新稳定版(allreleases 结果为倒序, 取首个稳定版) ----------
pecl_latest_stable() {
    { curl -fsSL "https://pecl.php.net/rest/r/$1/allreleases.xml" 2>/dev/null || true; } \
        | grep -oE '<v>[^<]+</v>' \
        | sed -e 's|<v>||' -e 's|</v>||' \
        | while read -r v; do is_stable "$v" && echo "$v"; done \
        | awk 'NR==1{v=$0} END{print v}' || true
}

# ---------- 取指定 PHP 版本的 ZEND_MODULE_API_NO(扩展目录后缀, 如 20250925) ----------
zend_api_no() {
    { curl -fsSL "https://raw.githubusercontent.com/php/php-src/php-$1/Zend/zend_modules.h" 2>/dev/null || true; } \
        | grep -oP '#define ZEND_MODULE_API_NO\s+\K[0-9]+' | head -1 || true
}

CHANGED=0
SUMMARY=""

# ---------- 通用更新函数: $1=ARG名 $2=最新版本 ----------
try_update() {
    local arg="$1" latest="$2" current
    [ -z "$latest" ] && { echo "  [$arg] 获取最新版本失败, 跳过"; return 0; }
    current=$(grep -oP "ARG ${arg}=\K.*" "$DOCKERFILE" | head -1 || true)
    [ -z "$current" ] && { echo "  [$arg] Dockerfile 中未找到, 跳过"; return 0; }
    if [ "$current" = "$latest" ]; then
        echo "  [$arg] 已是最新 ($current)"
    elif version_gt "$latest" "$current"; then
        echo "  [$arg] 更新: $current => $latest"
        sed -i "s|^ARG ${arg}=.*|ARG ${arg}=${latest}|" "$DOCKERFILE"
        CHANGED=1
        SUMMARY="${SUMMARY}\n- ${arg}: ${current} => ${latest}"
    else
        echo "  [$arg] 远程版本($latest)不高于当前($current), 跳过"
    fi
}

echo "===== 检查 PHP ====="
try_update PHP_VERSION "$(php_latest)"

echo "===== 检查 PECL 扩展(仅稳定版) ====="
try_update REDIS_VERSION "$(pecl_latest_stable redis)"
try_update SWOOLE_VERSION "$(pecl_latest_stable swoole)"
try_update MONGODB_VERSION "$(pecl_latest_stable mongodb)"

# ---------- php.ini 的 extension_dir 跟随 PHP 版本自动更新 ----------
CURRENT_PHP=$(grep -oP 'ARG PHP_VERSION=\K.*' "$DOCKERFILE" | head -1 || true)
API_NO=$(zend_api_no "$CURRENT_PHP")
if [ -n "$API_NO" ]; then
    OLD_LINE=$(grep -E '^extension_dir' "$PHP_INI" | head -1 || true)
    NEW_LINE="extension_dir = \"/data/php/lib/php/extensions/no-debug-non-zts-${API_NO}/\""
    if [ "$OLD_LINE" != "$NEW_LINE" ]; then
        echo "  [extension_dir] 更新: ${OLD_LINE} => ${NEW_LINE}"
        sed -i -E "s|^extension_dir = .*|${NEW_LINE}|" "$PHP_INI"
        CHANGED=1
        SUMMARY="${SUMMARY}\n- extension_dir: ${OLD_LINE} => ${NEW_LINE}"
    else
        echo "  [extension_dir] 已匹配 PHP ${CURRENT_PHP} (${API_NO})"
    fi
else
    echo "  [extension_dir] 获取 ZEND_MODULE_API_NO 失败, 跳过"
fi

echo ""
if [ "$CHANGED" = "1" ]; then
    echo "检测到版本更新:"
    echo -e "$SUMMARY"
else
    echo "所有版本均为最新, 无需更新"
fi

# 写入 GitHub Actions 环境(本地执行时跳过)
if [ -n "${GITHUB_ENV:-}" ]; then
    {
        echo "CHANGED=${CHANGED}"
        echo "SUMMARY<<EOF"
        echo -e "$SUMMARY"
        echo "EOF"
    } >> "$GITHUB_ENV"
fi
