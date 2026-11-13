<?php
// 더미 Queue 워커 (supervisor program lc-worker 가 실행).
// 1분마다 heartbeat 를 남기고, 매 틱마다 WORKER_JOB_SECONDS(기본 20초)짜리 "작업"을 흉내 낸다.
// supervisor 가 SIGTERM 을 보내면 진행 중인 작업을 끝까지 마친 뒤 종료한다 (graceful stop).
//   -> supervisor 의 stopwaitsecs(90) 가 이 작업 시간보다 길어야 SIGKILL 없이 끝난다.
//   -> 배포 중 stop.sh 가 `supervisorctl stop` 하면 로그에 "SIGTERM ... graceful exit" 이 남는다.
// 로그: storage/logs/worker.log, storage/logs/heartbeat.log
declare(strict_types=1);

require __DIR__ . '/heartbeat.php';

$stop = false;
if (function_exists('pcntl_async_signals')) {
    pcntl_async_signals(true);
    $handler = static function () use (&$stop): void {
        $stop = true;
        lc_log('worker.log', 'event=sigterm msg="finish current job, then exit"');
    };
    pcntl_signal(SIGTERM, $handler);
    pcntl_signal(SIGINT, $handler);
} else {
    lc_log('worker.log', 'warn=pcntl_missing graceful stop not available');
}

$jobSeconds = (int) (getenv('WORKER_JOB_SECONDS') ?: 20);
$rev = lc_revision();
lc_log('worker.log', sprintf('event=start sha=%s pid=%d job_seconds=%d', substr($rev['sha'], 0, 7), getmypid(), $jobSeconds));

$n = 0;
while (!$stop) {
    $n++;
    lc_heartbeat('queue');
    lc_log('worker.log', "event=job_start n=$n");
    for ($i = 0; $i < $jobSeconds; $i++) {
        sleep(1); // SIGTERM 이 와도 for 를 끝까지 돈다 = 작업 완료 후 종료
    }
    lc_log('worker.log', "event=job_done n=$n");
    for ($i = 0; $i < 60 - $jobSeconds && !$stop; $i++) {
        sleep(1);
    }
}
lc_log('worker.log', 'event=exit msg="graceful exit"');
exit(0);
