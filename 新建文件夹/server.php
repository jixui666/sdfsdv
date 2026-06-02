<?php
/**
 * TCP 1996 服务端（PHP CLI）
 *
 * 启动:
 *   php server.php
 *   php server.php /path/to/config.php
 *
 * 修改下发: 编辑 config.php
 */
declare(strict_types=1);

require __DIR__ . '/lib.php';

$configPath = $argv[1] ?? null;
$cfg = kyfbs1996_load_config($configPath);

$host = $cfg['listen_host'] ?? '0.0.0.0';
$port = (int) ($cfg['listen_port'] ?? 1996);

$errno = 0;
$errstr = '';
$server = @stream_socket_server("tcp://{$host}:{$port}", $errno, $errstr);
if ($server === false) {
    fwrite(STDERR, "Listen failed: {$errstr} ({$errno})\n");
    exit(1);
}

echo "[" . date('Y-m-d H:i:s') . "] listening on {$host}:{$port}\n";
echo "lib version: " . (defined('KYFBS1996_LIB_VERSION') ? KYFBS1996_LIB_VERSION : 'OLD-missing-line_map') . "\n";
echo "Default link: " . ($cfg['link'] ?? '(see routes)') . "\n";

while (true) {
    $client = @stream_socket_accept($server, -1);
    if ($client === false) {
        continue;
    }

    $peer = @stream_socket_get_name($client, true) ?: 'unknown';
    $hello = kyfbs1996_read_client_hello($client);
    $helloPrint = $hello === '' ? '(empty)' : bin2hex($hello) . ' | ' . preg_replace('/[^\x20-\x7E]/', '.', $hello);
    $profileInfo = kyfbs1996_detect_profile_info($hello);

    try {
        $payload = kyfbs1996_pick_payload($cfg, $hello);
        $packet = kyfbs1996_build_packet($payload);
        $sent = kyfbs1996_send_packet($client, $packet);
        $plain = (substr($hello, 0, 2) === "\x1f\x8b") ? @gzdecode($hello) : $hello;
        $route = $payload['_route'] ?? '?';
        echo "[" . date('Y-m-d H:i:s') . "] {$peer} route={$route}\n";
        if ($plain) {
            echo "  request=" . trim($plain) . "\n";
        } else {
            echo "  hello={$helloPrint}\n";
        }
        echo "  request_bytes=" . strlen($hello) . "\n";
        echo "  request_gzip=" . (substr($hello, 0, 2) === "\x1f\x8b" ? 'yes' : 'no') . "\n";
        if ($profileInfo['has_profile']) {
            $p = $profileInfo['profile'];
            $summary = [
                'fb_id' => $p['fb_id'] ?? null,
                'customID' => $p['customID'] ?? null,
                'lang' => $p['lang'] ?? null,
                'platform' => $p['platform'] ?? null,
            ];
            echo "  request_profile_json=yes source={$profileInfo['source']}\n";
            echo "  request_profile_summary=" . json_encode($summary, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE) . "\n";
        } else {
            echo "  request_profile_json=no\n";
        }
        echo "  -> link={$payload['link']}\n";
        echo "  response_bytes=" . strlen($packet) . " sent={$sent}\n";
        echo "  lib=" . KYFBS1996_LIB_VERSION . "\n";
    } catch (Throwable $e) {
        echo "[" . date('Y-m-d H:i:s') . "] {$peer} ERROR: {$e->getMessage()}\n";
    }

    @fclose($client);
}
