<?php
// 더미 heartbeat. 사용: php heartbeat.php <scheduler|queue>
//   Scheduler 서버: cron 이 1분마다 호출 (/etc/cron.d/lc-scheduler, start.sh 가 설치)
//   Queue 서버    : bin/worker.php 가 1분마다 같은 함수를 호출
// 어느 서버에서 돌았는지(host, instance-id)와 어느 릴리스 코드였는지(sha)를 로그에 남긴다.
// 로그: <release>/storage/logs/heartbeat.log (= /var/www/shared/storage/logs/heartbeat.log)
declare(strict_types=1);

require __DIR__ . '/../src/lib.php';

function lc_heartbeat(string $kind): void
{
    $rev = lc_revision();
    lc_log('heartbeat.log', sprintf(
        'kind=%s host=%s instance=%s sha=%s pid=%d',
        $kind,
        gethostname(),
        lc_imds()['instance_id'],
        substr($rev['sha'], 0, 7),
        getmypid()
    ));
}

if (PHP_SAPI === 'cli' && realpath($_SERVER['SCRIPT_FILENAME'] ?? '') === __FILE__) {
    lc_heartbeat($argv[1] ?? 'scheduler');
}
