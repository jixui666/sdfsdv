<?php
const KYFBS1996_LIB_VERSION = '20260603-graceful-close';

/** 写满响应包并半关闭写端，避免 iOS StreamTask 因过早 FIN 报 read-side closed */
function kyfbs1996_send_packet($socket, string $packet): int
{
    $total = strlen($packet);
    $written = 0;
    while ($written < $total) {
        $n = @fwrite($socket, substr($packet, $written));
        if ($n === false || $n === 0) {
            break;
        }
        $written += $n;
    }

    // 半关闭写端：数据发完后发 FIN，但保持读端，给 iOS 留时间收完包
    @stream_socket_shutdown($socket, STREAM_SHUT_WR);
    usleep(200000);

    return $written;
}
function kyfbs1996_load_config(?string $configPath = null): array
{
    $path = $configPath ?? __DIR__ . '/config.php';
    if (!is_file($path)) {
        throw new RuntimeException("Config not found: {$path}");
    }
    $cfg = require $path;
    if (!is_array($cfg)) {
        throw new RuntimeException('Config must return an array');
    }
    return $cfg;
}

function kyfbs1996_read_client_hello($socket, int $maxBytes = 8192, int $timeoutSec = 3): string
{
    stream_set_timeout($socket, $timeoutSec);
    $data = '';
    while (strlen($data) < $maxBytes) {
        $chunk = @fread($socket, $maxBytes - strlen($data));
        if ($chunk === false || $chunk === '') {
            break;
        }
        $data .= $chunk;
        $meta = stream_get_meta_data($socket);
        if (!empty($meta['eof'])) {
            break;
        }
        if (strlen($data) >= 54 && substr($data, 0, 2) === "\x1f\x8b") {
            break;
        }
    }
    return $data;
}

/**
 * 解析 App 请求，返回路由键列表（优先级从高到低）
 */
function kyfbs1996_parse_client_request(string $raw): array
{
    $keys = [];
    if ($raw === '') {
        return ['default', '3'];
    }

    // App 标准: 整包 gzip → setting.txt#线路号
    if (substr($raw, 0, 2) === "\x1f\x8b") {
        $plain = @gzdecode($raw);
        if (is_string($plain) && $plain !== '') {
            $plain = trim($plain);
            $keys[] = $plain;
            if (preg_match('/^(.+)#(\d+)$/', $plain, $m)) {
                $keys[] = $m[1] . '#' . $m[2];
                $keys[] = $m[2]; // "3" 或 "4"
            }
        }
    }

    // 兼容 test.php: 00000000 / ADS_PLAN / 明文 token#1
    if (preg_match('/^[\x20-\x7E]+$/', $raw)) {
        $text = trim($raw);
        $keys[] = $text;
        if (preg_match('/^(.+)#(\d+)$/', $text, $m)) {
            $keys[] = $m[2];
        }
    }

    if (strlen($raw) === 4) {
        $keys[] = (string) unpack('N', $raw)[1];
    }

    $keys[] = 'default';
    $keys[] = '3';

    $out = [];
    foreach ($keys as $k) {
        if ($k !== '' && !in_array($k, $out, true)) {
            $out[] = $k;
        }
    }
    return $out;
}

function kyfbs1996_line_map(array $cfg): array
{
    $map = $cfg['line_map'] ?? [];
    if ($map === []) {
        $map = [
            '3' => 'https://www.adsapi.top?type=1',
            '4' => 'https://www.adsapi.top?type=2',
        ];
    }
    return $map;
}

function kyfbs1996_pick_payload(array $cfg, string $clientHello = ''): array
{
    $extInfo = (string) ($cfg['extInfo'] ?? 'NSURL#URLWithString:#loadRequest:#0#baseURL|baseURL#WebKit');
    $defaultLink = (string) ($cfg['link'] ?? 'https://www.adsapi.top?type=1');
    $routes = $cfg['routes'] ?? [];
    if (!is_array($routes)) {
        $routes = [];
    }
    $lineMap = kyfbs1996_line_map($cfg);

    // 优先：gzip 解压后的 #线路号（App 真实逻辑）
    if (substr($clientHello, 0, 2) === "\x1f\x8b") {
        $plain = @gzdecode($clientHello);
        if (is_string($plain) && preg_match('/#(\d+)\s*$/', trim($plain), $m)) {
            $line = $m[1];
            if (isset($lineMap[$line])) {
                return [
                    'link' => $lineMap[$line],
                    'extInfo' => $extInfo,
                    '_route' => 'line_map#' . $line,
                ];
            }
        }
    }

    foreach (kyfbs1996_parse_client_request($clientHello) as $key) {
        if (isset($routes[$key]) && is_array($routes[$key])) {
            $link = (string) ($routes[$key]['link'] ?? $defaultLink);
            return [
                'link' => kyfbs1996_normalize_link($link, $defaultLink),
                'extInfo' => (string) ($routes[$key]['extInfo'] ?? $extInfo),
                '_route' => $key,
            ];
        }
    }

    return [
        'link' => kyfbs1996_normalize_link($defaultLink, $defaultLink),
        'extInfo' => $extInfo,
        '_route' => 'default',
    ];
}

/** 防止匹配错乱后出现 https://www.adsapi.top? 无 type */
function kyfbs1996_normalize_link(string $link, string $fallback): string
{
    $link = trim($link);
    if ($link === '' || !preg_match('/type=\d+/i', $link)) {
        return $fallback;
    }
    return $link;
}

function kyfbs1996_build_packet(array $payload): string
{
    $link = $payload['link'] ?? '';
    if ($link === '' || !preg_match('/type=\d+/i', $link)) {
        throw new InvalidArgumentException('invalid link in payload');
    }
    $json = json_encode(
        [
            'link' => $link,
            'extInfo' => $payload['extInfo'] ?? 'NSURL#URLWithString:#loadRequest:#0#baseURL|baseURL#WebKit',
        ],
        JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE
    );
    if ($json === false) {
        throw new RuntimeException('json_encode failed');
    }
    $gzip = gzencode($json, 9);
    if ($gzip === false) {
        throw new RuntimeException('gzencode failed');
    }
    return pack('N', strlen($gzip)) . $gzip;
}

function kyfbs1996_parse_packet(string $binary): array
{
    if (strlen($binary) < 4) {
        throw new InvalidArgumentException('packet too short');
    }
    $length = unpack('N', substr($binary, 0, 4))[1];
    $body = substr($binary, 4, $length);
    $json = gzdecode($body);
    if ($json === false) {
        throw new RuntimeException('gzdecode failed');
    }
    $data = json_decode($json, true);
    if (!is_array($data)) {
        throw new RuntimeException('invalid json');
    }
    return $data;
}

/**
 * 解析请求里是否携带用户 JSON（明文或 gzip）。
 */
function kyfbs1996_detect_profile_info(string $hello): array
{
    $info = [
        'has_profile' => false,
        'source' => 'none',
        'profile' => null,
    ];

    $candidates = [
        ['source' => 'plain', 'raw' => $hello],
    ];

    if (substr($hello, 0, 2) === "\x1f\x8b") {
        $decoded = @gzdecode($hello);
        if (is_string($decoded) && $decoded !== '') {
            $candidates[] = ['source' => 'gzip', 'raw' => $decoded];
        }
    }

    foreach ($candidates as $candidate) {
        $raw = trim($candidate['raw']);
        if ($raw === '' || $raw[0] !== '{') {
            continue;
        }
        $data = json_decode($raw, true);
        if (!is_array($data)) {
            continue;
        }
        $info['has_profile'] = true;
        $info['source'] = $candidate['source'];
        $info['profile'] = $data;
        return $info;
    }

    return $info;
}
