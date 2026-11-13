<?php
// 최소 PHP 앱 공용 함수 (프레임워크/DB/Redis/세션 없음). 대충 만든 데모용이다.
// 값은 배포 번들 루트의 파일에서 읽는다:
//   REVISION    SHA= VERSION= TAG= BUILT_AT=        (GitHub Actions 가 작성)
//   FAULT       FAULT=<스위치> FAULT_TARGET=<대상>   (GitHub Actions 가 작성, 기본 none/all)
//   DEPLOY_INFO DEPLOYMENT_ID= ROLE= DEPLOYED_AT=    (after_install.sh 가 작성)
declare(strict_types=1);

date_default_timezone_set('Asia/Seoul');

function lc_root(): string
{
    // /var/www/current 는 심볼릭 링크지만 __DIR__ 는 실제 릴리스 경로(releases/<id>)로 풀린다.
    return dirname(__DIR__);
}

/** KEY=VALUE 파일 파서 (따옴표 허용, # 주석). 없으면 빈 배열. */
function lc_kv(string $file): array
{
    $out = [];
    $lines = @file($file, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES);
    if ($lines === false) {
        return $out;
    }
    foreach ($lines as $line) {
        $line = trim($line);
        if ($line === '' || $line[0] === '#' || strpos($line, '=') === false) {
            continue;
        }
        [$k, $v] = explode('=', $line, 2);
        $v = trim($v);
        if (strlen($v) >= 2 && ($v[0] === "'" || $v[0] === '"') && substr($v, -1) === $v[0]) {
            $v = substr($v, 1, -1);
        }
        $out[trim($k)] = $v;
    }
    return $out;
}

function lc_revision(): array
{
    $r = lc_kv(lc_root() . '/REVISION');
    return [
        'sha' => $r['SHA'] ?? 'unknown',
        'version' => $r['VERSION'] ?? '0.0.0-local',
        'tag' => $r['TAG'] ?? 'none',
        'built_at' => $r['BUILT_AT'] ?? '-',
    ];
}

function lc_deploy_info(): array
{
    $d = lc_kv(lc_root() . '/DEPLOY_INFO');
    return [
        'deployment_id' => $d['DEPLOYMENT_ID'] ?? '-',
        'role' => $d['ROLE'] ?? '-',
        'deployed_at' => $d['DEPLOYED_AT'] ?? '-',
    ];
}

/** SHA 앞 6자리 -> 색조. 릴리스가 바뀌면 배경색이 바뀐다. */
function lc_color(string $sha): string
{
    if (!preg_match('/^[0-9a-f]{6}/i', $sha)) {
        return 'hsl(0, 0%, 35%)';
    }
    $hue = hexdec(substr($sha, 0, 6)) % 360;
    return sprintf('hsl(%d, 65%%, 40%%)', $hue);
}

/**
 * IMDSv2 (토큰 -> 값). 실패해도 예외 없이 'unknown'. 결과는 짧게 캐시한다.
 * 캐시: 성공 60초, 실패 10초 (IMDS 가 막힌 환경에서 요청마다 지연되지 않게).
 */
function lc_imds(): array
{
    static $memo = null;
    if ($memo !== null) {
        return $memo;
    }
    $cache = sys_get_temp_dir() . '/lc-imds.json';
    $c = @json_decode((string) @file_get_contents($cache), true);
    if (is_array($c) && isset($c['at'], $c['ttl'], $c['data']) && time() - $c['at'] < $c['ttl']) {
        return $memo = $c['data'];
    }

    $base = 'http://169.254.169.254/latest';
    $tokCtx = stream_context_create(['http' => [
        'method' => 'PUT',
        'header' => "X-aws-ec2-metadata-token-ttl-seconds: 120\r\nContent-Length: 0\r\n",
        'timeout' => 0.5,
        'ignore_errors' => true,
    ]]);
    $token = @file_get_contents($base . '/api/token', false, $tokCtx);
    $data = ['instance_id' => 'unknown', 'az' => 'unknown', 'ok' => false];
    if (is_string($token) && $token !== '') {
        $ctx = stream_context_create(['http' => [
            'method' => 'GET',
            'header' => 'X-aws-ec2-metadata-token: ' . trim($token) . "\r\n",
            'timeout' => 0.5,
        ]]);
        $iid = @file_get_contents($base . '/meta-data/instance-id', false, $ctx);
        $az = @file_get_contents($base . '/meta-data/placement/availability-zone', false, $ctx);
        if (is_string($iid) && $iid !== '') {
            $data['instance_id'] = trim($iid);
            $data['ok'] = true;
        }
        if (is_string($az) && $az !== '') {
            $data['az'] = trim($az);
        }
    }
    @file_put_contents($cache, json_encode(['at' => time(), 'ttl' => $data['ok'] ? 60 : 10, 'data' => $data]));
    return $memo = $data;
}

/**
 * 고장 스위치. 번들의 FAULT 파일 값 + 서버 플래그 파일.
 * 반환: ['fault' => 스위치, 'target' => 대상, 'applies' => 이 인스턴스에 적용되는가]
 * 대상 문법은 scripts/lib.sh 의 fault_applies 와 같다:
 *   all | instance:i-aaa,i-bbb | az:ap-northeast-2c
 *   ssm 은 훅(scripts/lib.sh)만 SSM 파라미터로 판단한다. 앱 화면/ up500 은 ssm 대상을 판단하지 않는다(applies=false).
 */
function lc_fault(): array
{
    $f = lc_kv(lc_root() . '/FAULT');
    $fault = $f['FAULT'] ?? 'none';
    $target = $f['FAULT_TARGET'] ?? 'all';
    $applies = false;
    if ($fault !== 'none') {
        if ($target === 'all') {
            $applies = true;
        } elseif (strncmp($target, 'instance:', 9) === 0) {
            $applies = in_array(lc_imds()['instance_id'], explode(',', substr($target, 9)), true);
        } elseif (strncmp($target, 'az:', 3) === 0) {
            $applies = lc_imds()['az'] === substr($target, 3);
        }
    }
    return ['fault' => $fault, 'target' => $target, 'applies' => $applies];
}

/** /up 을 500 으로 만들지: 번들 FAULT=up500 (대상 일치) 또는 서버 플래그 파일 (T12: 배포 없이 한 대만). */
function lc_up_broken(): ?string
{
    if (is_file('/var/www/shared/FAULT_UP_500')) {
        return 'flag file /var/www/shared/FAULT_UP_500';
    }
    $f = lc_fault();
    if ($f['fault'] === 'up500' && $f['applies']) {
        return 'FAULT=up500 target=' . $f['target'];
    }
    return null;
}

function lc_log(string $file, string $line): void
{
    $dir = lc_root() . '/storage/logs';
    if (!is_dir($dir)) {
        $dir = sys_get_temp_dir();
    }
    @file_put_contents($dir . '/' . $file, date('c') . ' ' . $line . "\n", FILE_APPEND | LOCK_EX);
}

function lc_h(string $s): string
{
    return htmlspecialchars($s, ENT_QUOTES, 'UTF-8');
}
