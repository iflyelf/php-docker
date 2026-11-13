<?php
/**
 * Zabbix 前端依赖自检
 *
 * 依据: https://www.zabbix.com/documentation/8.0/zh/manual/installation/requirements#frontend
 * 用法: php /usr/local/bin/zabbix-check.php
 *
 * 任一项不满足返回非 0, 用于镜像构建期兜底, 也可在运行期手动执行排查。
 */

$minPhp = getenv('ZABBIX_MIN_PHP') ?: '8.5.12';

// Zabbix 8.0 前端必需扩展
$required = [
    'mysqli',      // MySQL 后端必需
    'pgsql',       // PostgreSQL 后端必需
    'bcmath',
    'mbstring',
    'sockets',     // 用户脚本所需
    'gd',          // 图形/地图, 需 PNG/JPEG/FreeType
    'libxml',      // >= 2.6.15
    'xml',
    'xmlwriter',
    'xmlreader',
    'ctype',
    'session',
    'ldap',        // LDAP 认证
    'openssl',     // SAML 认证
    'gettext',     // 翻译
    'curl',        // Duo MFA / SMTP 认证 (>= 7.19.4)
];

$errors = [];

$missing = array_values(array_filter($required, static fn(string $ext): bool => !extension_loaded($ext)));
if ($missing) {
    $errors[] = '缺少必需扩展: ' . implode(', ', $missing);
}

if (version_compare(PHP_VERSION, $minPhp, '<')) {
    $errors[] = sprintf('PHP %s 低于 Zabbix 安全基线 %s (CVE-2026-109618/109619)', PHP_VERSION, $minPhp);
}

$libxmlVersion = defined('LIBXML_DOTTED_VERSION') ? LIBXML_DOTTED_VERSION : '0';
if (version_compare($libxmlVersion, '2.6.15', '<')) {
    $errors[] = sprintf('libxml %s < 2.6.15', $libxmlVersion);
}

$curlVersion = extension_loaded('curl') ? (curl_version()['version'] ?? '0') : '0';
if (version_compare($curlVersion, '7.19.4', '<')) {
    $errors[] = sprintf('libcurl %s < 7.19.4', $curlVersion);
}

if (extension_loaded('gd')) {
    $gd = gd_info();
    foreach (['PNG Support', 'JPEG Support', 'FreeType Support'] as $feature) {
        if (empty($gd[$feature])) {
            $errors[] = 'GD 缺少 ' . $feature;
        }
    }
    if (!preg_match('/([0-9]+\.[0-9]+\.[0-9]+)/', $gd['GD Version'] ?? '', $m)
        || version_compare($m[1], '2.0.28', '<')) {
        $errors[] = 'GD 版本过低: ' . ($gd['GD Version'] ?? 'unknown');
    }
}

if ($errors) {
    fwrite(STDERR, "Zabbix 前端依赖自检失败:\n - " . implode("\n - ", $errors) . "\n");
    exit(1);
}

printf(
    "Zabbix 前端依赖自检通过: PHP %s / libxml %s / libcurl %s / GD %s (扩展 %d 项齐全)\n",
    PHP_VERSION,
    $libxmlVersion,
    $curlVersion,
    extension_loaded('gd') ? (gd_info()['GD Version'] ?? 'unknown') : 'n/a',
    count($required)
);
