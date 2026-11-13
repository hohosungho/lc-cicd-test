<?php
// 프론트 컨트롤러: nginx 가 모든 요청을 여기로 보낸다. 라우트는 / , /up , /version 뿐.
declare(strict_types=1);

require __DIR__ . '/../src/lib.php';

$path = parse_url($_SERVER['REQUEST_URI'] ?? '/', PHP_URL_PATH) ?: '/';

header('Cache-Control: no-store');

if ($path === '/up') {
    // 헬스체크 (ALB 타깃 그룹 / validate.sh). 고장 스위치가 켜져 있으면 500.
    $why = lc_up_broken();
    header('Content-Type: text/plain; charset=utf-8');
    if ($why !== null) {
        http_response_code(500);
        echo "DOWN ($why)\n";
        exit;
    }
    echo "OK\n";
    exit;
}

$rev = lc_revision();
$dep = lc_deploy_info();
$imds = lc_imds();

if ($path === '/version') {
    header('Content-Type: application/json');
    echo json_encode([
        'sha' => $rev['sha'],
        'version' => $rev['version'],
        'tag' => $rev['tag'],
        'instance_id' => $imds['instance_id'],
        'az' => $imds['az'],
        'role' => $dep['role'],
        'deployment_id' => $dep['deployment_id'],
        'time' => date('c'),
    ]);
    exit;
}

if ($path !== '/') {
    http_response_code(404);
    header('Content-Type: text/plain; charset=utf-8');
    echo "not found\n";
    exit;
}

$fault = lc_fault();
$bg = lc_color($rev['sha']);
$short = substr($rev['sha'], 0, 7);
$tail = substr($imds['instance_id'], -4);
?>
<!doctype html>
<html lang="ko">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>lc <?= lc_h($rev['version']) ?> @ <?= lc_h($tail) ?></title>
<style>
  body { margin:0; padding:24px; background:<?= lc_h($bg) ?>; color:#fff; font:20px/1.4 system-ui, sans-serif; }
  h1 { font-size:88px; margin:0 0 8px; letter-spacing:2px; }
  .row { font-size:44px; margin:6px 0; }
  .row b { opacity:.7; font-weight:400; font-size:24px; display:inline-block; min-width:170px; }
  .sm { font-size:16px; opacity:.8; word-break:break-all; }
  .fault { background:#c00; padding:10px 16px; margin-bottom:16px; font-size:28px; font-weight:700; }
  #strip { margin-top:24px; display:flex; flex-wrap:wrap; gap:4px; }
  #strip span { font:13px monospace; padding:4px 6px; border:1px solid #fff8; }
</style>
</head>
<body>
<?php if ($fault['fault'] !== 'none'): ?>
  <div class="fault">FAULT: <?= lc_h($fault['fault']) ?> target=<?= lc_h($fault['target']) ?> (<?= $fault['applies'] ? '이 서버에 적용됨' : '이 서버는 대상 아님' ?>)</div>
<?php endif; ?>
  <h1><?= lc_h($short) ?></h1>
  <div class="row"><b>version</b><?= lc_h($rev['version']) ?></div>
  <div class="row"><b>tag</b><?= lc_h($rev['tag']) ?></div>
  <div class="row"><b>instance-id</b><?= lc_h($imds['instance_id']) ?></div>
  <div class="row"><b>AZ</b><?= lc_h($imds['az']) ?></div>
  <div class="row"><b>server time</b><?= lc_h(date('Y-m-d H:i:s T')) ?></div>
  <div class="row"><b>role (group)</b><?= lc_h($dep['role']) ?></div>
  <p class="sm">release sha: <?= lc_h($rev['sha']) ?><br>
     deployment: <?= lc_h($dep['deployment_id']) ?> / deployed <?= lc_h($dep['deployed_at']) ?> / built <?= lc_h($rev['built_at']) ?><br>
     host: <?= lc_h((string) gethostname()) ?> / IMDS: <?= $imds['ok'] ? 'ok' : '실패(unknown 표시)' ?></p>
  <!-- 롤링 배포 중 ALB 가 어느 서버로 보내는지: 1초마다 /version 을 호출해 칩으로 쌓는다 -->
  <div id="strip"></div>
<script>
  var strip = document.getElementById('strip');
  function hue(s) { return /^[0-9a-f]{6}/i.test(s) ? parseInt(s.slice(0, 6), 16) % 360 : 0; }
  function tick() {
    fetch('/version', { cache: 'no-store' }).then(function (r) {
      if (!r.ok) { throw new Error(r.status); }
      return r.json();
    }).then(function (j) {
      add(j.sha.slice(0, 7) + ' ' + j.instance_id.slice(-4), 'hsl(' + hue(j.sha) + ',65%,40%)');
    }).catch(function (e) { add('ERR ' + e.message, '#c00'); });
  }
  function add(text, bg) {
    var s = document.createElement('span');
    s.textContent = text; s.style.background = bg;
    strip.insertBefore(s, strip.firstChild);
    while (strip.children.length > 40) { strip.removeChild(strip.lastChild); }
  }
  setInterval(tick, 1000);
</script>
</body>
</html>
