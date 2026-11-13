# CLI 가이드 (lc CodeDeploy + ASG 데모)

`CONSOLE-GUIDE.md` 와 같은 구성을 AWS CLI 로 만들고 운영하는 방법이다. 순서와 값은 CONSOLE-GUIDE 와 같다. 콘솔로 만들었다면 이 문서는 "배포 실행·시험·정리" 부분(§8~§13)만 보면 된다.
셸은 bash/zsh 기준이다. 대괄호 `[]` 가 들어간 인자는 zsh 에서 깨지지 않게 따옴표로 감쌌다. 실행 전 §0 을 먼저 한다.

---
## 0. 준비: 계정 확인과 변수
```bash
export AWS_REGION=ap-northeast-2 AWS_DEFAULT_REGION=ap-northeast-2
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
[ "$ACCOUNT" = "866477832211" ] || { echo "계정이 다릅니다: $ACCOUNT"; return 1 2>/dev/null || exit 1; }
MY_IP=$(curl -s https://checkip.amazonaws.com)      # ALB 인바운드 허용용. 터미널에만 쓰고 파일/깃에 적지 않는다
echo "$ACCOUNT $MY_IP"

# 태그 헬퍼: tag <리소스타입> <Name> [추가태그 Key=..,Value=.. 형식의 {..}]
tag() { echo "ResourceType=$1,Tags=[{Key=Name,Value=$2},{Key=Project,Value=lcamtest},{Key=Owner,Value=sungho},{Key=Ephemeral,Value=true}${3:+,$3}]"; }
```
중간 결과(ID)는 쉘 변수에 담고, 터미널을 닫아도 이어서 하려면 파일에 저장해 둔다(`.lc-vars` 는 `.gitignore` 에 들어 있다):
```bash
save() { echo "export $1=\"${!1}\"" >> .lc-vars; }      # 사용: save VPC   /  이어서 하기: source .lc-vars
```
(zsh 는 `${!1}` 대신 `${(P)1}`)

## 1. 네트워크
```bash
VPC=$(aws ec2 create-vpc --cidr-block 10.0.0.0/16 --tag-specifications "$(tag vpc lc-vpc)" --query Vpc.VpcId --output text)
aws ec2 modify-vpc-attribute --vpc-id $VPC --enable-dns-hostnames '{"Value":true}'
SUB_A=$(aws ec2 create-subnet --vpc-id $VPC --cidr-block 10.0.0.0/24 --availability-zone ap-northeast-2a --tag-specifications "$(tag subnet lc-public-2a)" --query Subnet.SubnetId --output text)
SUB_C=$(aws ec2 create-subnet --vpc-id $VPC --cidr-block 10.0.1.0/24 --availability-zone ap-northeast-2c --tag-specifications "$(tag subnet lc-public-2c)" --query Subnet.SubnetId --output text)
for s in $SUB_A $SUB_C; do aws ec2 modify-subnet-attribute --subnet-id $s --map-public-ip-on-launch; done
IGW=$(aws ec2 create-internet-gateway --tag-specifications "$(tag internet-gateway lc-igw)" --query InternetGateway.InternetGatewayId --output text)
aws ec2 attach-internet-gateway --internet-gateway-id $IGW --vpc-id $VPC
RT=$(aws ec2 create-route-table --vpc-id $VPC --tag-specifications "$(tag route-table lc-public-rt)" --query RouteTable.RouteTableId --output text)
aws ec2 create-route --route-table-id $RT --destination-cidr-block 0.0.0.0/0 --gateway-id $IGW
for s in $SUB_A $SUB_C; do aws ec2 associate-route-table --route-table-id $RT --subnet-id $s >/dev/null; done
aws ec2 create-vpc-endpoint --vpc-id $VPC --vpc-endpoint-type Gateway --service-name com.amazonaws.ap-northeast-2.s3 --route-table-ids $RT \
  --tag-specifications "$(tag vpc-endpoint lc-s3-gw)" >/dev/null
```
NAT 게이트웨이는 만들지 않는다. 확인: `aws ec2 describe-route-tables --route-table-ids $RT --query 'RouteTables[0].Routes'` 에 `0.0.0.0/0 → igw-…` 와 S3 엔드포인트 경로가 있다.

## 2. S3 ★
```bash
B=lc-deploy-$ACCOUNT
aws s3api create-bucket --bucket $B --create-bucket-configuration LocationConstraint=ap-northeast-2
aws s3api put-public-access-block --bucket $B --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
aws s3api put-bucket-encryption --bucket $B --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
aws s3api put-bucket-tagging --bucket $B --tagging 'TagSet=[{Key=Project,Value=lcamtest},{Key=Owner,Value=sungho},{Key=Ephemeral,Value=true}]'
```

## 3. IAM
```bash
mkdir -p /tmp/lc-iam && cd /tmp/lc-iam
cat > ec2-trust.json <<'EOF'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}
EOF
cat > cd-trust.json <<'EOF'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"codedeploy.amazonaws.com"},"Action":"sts:AssumeRole"}]}
EOF
cat > ec2-inline.json <<EOF
{"Version":"2012-10-17","Statement":[
 {"Effect":"Allow","Action":["s3:GetObject","s3:GetObjectVersion"],"Resource":"arn:aws:s3:::lc-deploy-$ACCOUNT/*"},
 {"Effect":"Allow","Action":["s3:ListBucket"],"Resource":"arn:aws:s3:::lc-deploy-$ACCOUNT"},
 {"Effect":"Allow","Action":["s3:GetObject","s3:ListBucket"],"Resource":["arn:aws:s3:::aws-codedeploy-ap-northeast-2","arn:aws:s3:::aws-codedeploy-ap-northeast-2/*"]}
]}
EOF
IT=(Key=Project,Value=lcamtest Key=Owner,Value=sungho Key=Ephemeral,Value=true)   # 배열: bash/zsh 모두 --tags "${IT[@]}" 로 쓴다
# 인스턴스 역할 + 프로파일
aws iam create-role --role-name lc-ec2-role --assume-role-policy-document file://ec2-trust.json --tags "${IT[@]}" >/dev/null
aws iam attach-role-policy --role-name lc-ec2-role --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
aws iam put-role-policy --role-name lc-ec2-role --policy-name lc-ec2-inline --policy-document file://ec2-inline.json
aws iam create-instance-profile --instance-profile-name lc-ec2-profile --tags "${IT[@]}" >/dev/null
aws iam add-role-to-instance-profile --instance-profile-name lc-ec2-profile --role-name lc-ec2-role
# CodeDeploy 서비스 역할
CD_ROLE_ARN=$(aws iam create-role --role-name lc-codedeploy-role --assume-role-policy-document file://cd-trust.json --tags "${IT[@]}" --query Role.Arn --output text)
aws iam attach-role-policy --role-name lc-codedeploy-role --policy-arn arn:aws:iam::aws:policy/service-role/AWSCodeDeployRole
# GitHub OIDC 공급자 + 역할
# 이미 있으면 'EntityAlreadyExists' 에러가 나는데, 그대로 두고 넘어가면 된다(계정에 공급자는 URL 당 하나만 만들 수 있다)
aws iam create-open-id-connect-provider --url https://token.actions.githubusercontent.com --client-id-list sts.amazonaws.com >/dev/null || true
cat > gh-trust.json <<EOF
{"Version":"2012-10-17","Statement":[{"Effect":"Allow",
 "Principal":{"Federated":"arn:aws:iam::$ACCOUNT:oidc-provider/token.actions.githubusercontent.com"},
 "Action":"sts:AssumeRoleWithWebIdentity",
 "Condition":{
  "StringEquals":{"token.actions.githubusercontent.com:aud":"sts.amazonaws.com"},
  "StringLike":{"token.actions.githubusercontent.com:sub":[
    "repo:hohosungho/lc-cicd-test:ref:refs/heads/main",
    "repo:hohosungho@*/lc-cicd-test@*:ref:refs/heads/main"]}}}]}
EOF
cat > gh-inline.json <<EOF
{"Version":"2012-10-17","Statement":[
 {"Effect":"Allow","Action":["s3:PutObject"],"Resource":"arn:aws:s3:::lc-deploy-$ACCOUNT/deploy/*"},
 {"Effect":"Allow","Action":["codedeploy:CreateDeployment","codedeploy:GetDeployment","codedeploy:GetDeploymentConfig","codedeploy:GetApplicationRevision","codedeploy:RegisterApplicationRevision"],"Resource":"*"}
]}
EOF
GH_ROLE_ARN=$(aws iam create-role --role-name lc-github-oidc-role --assume-role-policy-document file://gh-trust.json --tags "${IT[@]}" --query Role.Arn --output text)
aws iam put-role-policy --role-name lc-github-oidc-role --policy-name lc-github-deploy --policy-document file://gh-inline.json
cd - >/dev/null; echo "$CD_ROLE_ARN"; echo "$GH_ROLE_ARN"
```
`sub` 두 형식을 허용하는 이유는 CONSOLE-GUIDE 3-3 참고. 인스턴스 프로파일은 만든 직후 10초 정도 지나야 `run-instances` 에서 인식되는 경우가 있다.
(선택: T7 의 `fault_target=ssm` 을 쓰려면 CONSOLE-GUIDE 3-1 의 `ssm:GetParameter` 항목을 `ec2-inline.json` 에 추가하고, `aws ssm put-parameter --name /lcamtest/prd/FAULT_INSTANCE_IDS --type String --value i-xxx`.)

## 4. 보안 그룹
```bash
ALB_SG=$(aws ec2 create-security-group --group-name lc-alb-sg --description "lc alb" --vpc-id $VPC --tag-specifications "$(tag security-group lc-alb-sg)" --query GroupId --output text)
EC2_SG=$(aws ec2 create-security-group --group-name lc-ec2-sg --description "lc ec2" --vpc-id $VPC --tag-specifications "$(tag security-group lc-ec2-sg)" --query GroupId --output text)
aws ec2 authorize-security-group-ingress --group-id $ALB_SG --protocol tcp --port 80 --cidr $MY_IP/32
aws ec2 authorize-security-group-ingress --group-id $EC2_SG --protocol tcp --port 80 --source-group $ALB_SG
```
SSH 규칙은 만들지 않는다. 접속은 SSM Session Manager.

## 5. 인스턴스 (단독 Web, Queue, Scheduler)
```bash
UBUNTU_AMI=$(aws ssm get-parameter --name /aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id --query Parameter.Value --output text)
# 저장소 루트(lcam-cicd-demo)에서 실행. install.sh 는 AWS CLI 가 user-data 로 base64 인코딩해 보낸다
launch() { # 사용: launch <Name태그> <서브넷> [추가태그]
  aws ec2 run-instances --image-id "$UBUNTU_AMI" --instance-type t3.small --subnet-id "$2" --security-group-ids $EC2_SG \
    --associate-public-ip-address --iam-instance-profile Name=lc-ec2-profile \
    --metadata-options HttpTokens=required,HttpPutResponseHopLimit=2,HttpEndpoint=enabled \
    --block-device-mappings 'DeviceName=/dev/sda1,Ebs={VolumeSize=10,VolumeType=gp3,Encrypted=true}' \
    --user-data file://ami/install.sh \
    --tag-specifications "$(tag instance "$1" "$3")" "$(tag volume "$1")" \
    --query 'Instances[0].InstanceId' --output text
}
WEB_ID=$(launch lcamtest-web $SUB_A '{Key=lc-deploy,Value=web-standalone}')
Q_ID=$(launch lcamtest-queue $SUB_A)
S_ID=$(launch lcamtest-scheduler $SUB_C)
aws ec2 wait instance-running --instance-ids $WEB_ID $Q_ID $S_ID
```
설치 확인 (세션 관리자. `session-manager-plugin` 이 로컬에 설치돼 있어야 한다):
```bash
aws ssm describe-instance-information --query 'InstanceInformationList[].[InstanceId,PingStatus]' --output text   # Online 이 될 때까지 몇 분
aws ssm start-session --target $WEB_ID
# 세션 안에서: sudo tail -n 20 /var/log/lc-install.log ; systemctl is-active nginx php8.4-fpm supervisor cron codedeploy-agent
```
`install.sh` 가 끝나기까지 몇 분 걸린다. 마지막 줄이 `=== lc install 완료`.

## 6. 타깃 그룹과 ALB
```bash
TG_ARN=$(aws elbv2 create-target-group --name lc-web-tg --protocol HTTP --port 80 --vpc-id $VPC --target-type instance \
  --health-check-path /up --health-check-interval-seconds 30 --healthy-threshold-count 5 --unhealthy-threshold-count 2 --matcher HttpCode=200 \
  --tags Key=Project,Value=lcamtest Key=Owner,Value=sungho Key=Ephemeral,Value=true --query 'TargetGroups[0].TargetGroupArn' --output text)
# 프로파일 A (고객 현재값): 간격 30 / healthy 5 / unhealthy 2 / 등록 취소 지연 300
aws elbv2 modify-target-group-attributes --target-group-arn $TG_ARN --attributes Key=deregistration_delay.timeout_seconds,Value=300
ALB_ARN=$(aws elbv2 create-load-balancer --name lc-alb --type application --scheme internet-facing --subnets $SUB_A $SUB_C --security-groups $ALB_SG \
  --tags Key=Project,Value=lcamtest Key=Owner,Value=sungho Key=Ephemeral,Value=true --query 'LoadBalancers[0].LoadBalancerArn' --output text)
aws elbv2 create-listener --load-balancer-arn $ALB_ARN --protocol HTTP --port 80 --default-actions "Type=forward,TargetGroupArn=$TG_ARN" >/dev/null
ALB_DNS=$(aws elbv2 describe-load-balancers --load-balancer-arns $ALB_ARN --query 'LoadBalancers[0].DNSName' --output text); echo $ALB_DNS
```
프로파일 B 로 바꾸기 (T17): 
```bash
aws elbv2 modify-target-group --target-group-arn $TG_ARN --health-check-interval-seconds 10 --healthy-threshold-count 2 --unhealthy-threshold-count 2
aws elbv2 modify-target-group-attributes --target-group-arn $TG_ARN --attributes Key=deregistration_delay.timeout_seconds,Value=30
# A 로 되돌리기: 간격 30 / healthy 5 / unhealthy 2 / delay 300 으로 같은 명령 실행
```
대상은 등록하지 않는다. CodeDeploy 가 등록한다.

## 7. CodeDeploy 애플리케이션과 배포 그룹
```bash
aws deploy create-application --application-name lc-app --compute-platform Server
aws deploy create-deployment-group --application-name lc-app --deployment-group-name lc-web --service-role-arn $CD_ROLE_ARN \
  --deployment-config-name CodeDeployDefault.OneAtATime \
  --deployment-style deploymentType=IN_PLACE,deploymentOption=WITH_TRAFFIC_CONTROL \
  --load-balancer-info "targetGroupInfoList=[{name=lc-web-tg}]" \
  --ec2-tag-set 'ec2TagSetList=[[{Key=lc-deploy,Value=web-standalone,Type=KEY_AND_VALUE}]]' \
  --auto-rollback-configuration enabled=true,events=DEPLOYMENT_FAILURE \
  --outdated-instances-strategy UPDATE
for g in queue scheduler; do
  aws deploy create-deployment-group --application-name lc-app --deployment-group-name lc-$g --service-role-arn $CD_ROLE_ARN \
    --deployment-config-name CodeDeployDefault.AllAtOnce \
    --deployment-style deploymentType=IN_PLACE,deploymentOption=WITHOUT_TRAFFIC_CONTROL \
    --ec2-tag-set "ec2TagSetList=[[{Key=Name,Value=lcamtest-$g,Type=KEY_AND_VALUE}]]" \
    --auto-rollback-configuration enabled=true,events=DEPLOYMENT_FAILURE
done
aws deploy list-deployment-groups --application-name lc-app
```
확인: 콘솔 배포 그룹 화면의 "일치하는 인스턴스" 가 1 이거나, `aws deploy list-deployment-instances` 는 배포 후에만 나온다. 에이전트가 안 뜬 인스턴스는 배포에서 "대상 없음" 으로 실패한다.

## 8. GitHub 변수 설정 (gh CLI)
```bash
R=hohosungho/lc-cicd-test
gh variable set AWS_ROLE_ARN        --repo $R --body "$GH_ROLE_ARN"
gh variable set AWS_REGION          --repo $R --body ap-northeast-2
gh variable set DEPLOY_BUCKET       --repo $R --body "lc-deploy-$ACCOUNT"
gh variable set CD_APPLICATION      --repo $R --body lc-app
gh variable set CD_GROUP_WEB        --repo $R --body lc-web
gh variable set CD_GROUP_QUEUE      --repo $R --body lc-queue
gh variable set CD_GROUP_SCHEDULER  --repo $R --body lc-scheduler
gh variable list --repo $R
```

## 9. 앱을 바꾸고 GitHub Actions 로 배포하기
`deploy.yml` 은 `main` 에 push 하면 자동 실행된다(단 `docs/**`, `*.md` 만 바뀐 push 는 실행되지 않는다). 수동 실행으로 고장 스위치와 태그를 줄 수 있다.
```bash
cd lcam-cicd-demo
# (a) 앱 수정 → push: 화면이 바뀐다. 색은 커밋 SHA 에서 만들어지므로 커밋마다 배경색이 달라진다
$EDITOR app/public/index.php            # 예: <h1> 아래에 문구 추가
git add -A && git commit -m "app: change title" && git push
# (b) 코드 변경 없이 새 릴리스만 만들기 (색·버전·SHA 가 바뀜)
git commit --allow-empty -m "deploy: v2" && git push
# (c) 수동 실행 (정상 / 고장 / 태그 표시)
gh workflow run deploy --repo hohosungho/lc-cicd-test -f fault=none -f fault_target=all -f release_tag=v2
gh workflow run deploy --repo hohosungho/lc-cicd-test -f fault=validate_fail -f fault_target=all -f release_tag=bad
# 진행 보기
gh run list --repo hohosungho/lc-cicd-test --limit 3
gh run watch --repo hohosungho/lc-cicd-test            # 실행 선택 후 실시간
```
화면에 보이는 값: 버전 `1.0.<실행 번호>`, 태그(= `release_tag` 입력, 비우면 브랜치 이름), 커밋 SHA, 그 SHA 로 만든 배경색, instance-id, AZ. 수동 실행은 `main` 의 현재 커밋 SHA 를 쓴다. 같은 SHA 로 다시 돌리면 색은 같고 버전/태그만 바뀐다.
고장 스위치 값과 대상은 `scripts/README.md` 에 있다.

## 10. 배포 진행 보기 (CodeDeploy)
```bash
aws deploy list-deployments --application-name lc-app --deployment-group-name lc-web --max-items 5 --query 'deployments' --output text
D=<배포 ID>
aws deploy get-deployment --deployment-id $D --query 'deploymentInfo.{status:status,rollback:rollbackInfo,error:errorInformation,desc:description}'
aws deploy list-deployment-targets --deployment-id $D                                  # 인스턴스별 처리 순서 확인
aws deploy get-deployment-target --deployment-id $D --target-id <instance-id> \
  --query 'deploymentTarget.instanceTarget.lifecycleEvents[].[lifecycleEventName,status,startTime,endTime]' --output table
aws elbv2 describe-target-health --target-group-arn $TG_ARN --query 'TargetHealthDescriptions[].[Target.Id,TargetHealth.State]' --output text
```
이벤트별 훅 로그는 서버에서: `sudo tail -n 80 /opt/codedeploy-agent/deployment-root/deployment-logs/codedeploy-agent-deployments.log` (경로는 첫 배포 때 확인).
버전 연속 확인(롤링 중): `while true; do date +%T; curl -s http://$ALB_DNS/version; echo; sleep 0.5; done`

## 11. 첫 배포 후 골든 AMI
```bash
aws ssm start-session --target $WEB_ID
# 세션 안에서:
#   curl -s localhost/version ; ls -l /var/www/current /var/www/releases
#   sudo cp /var/www/current/ami/pre-bake-cleanup.sh /tmp/pre-bake-cleanup.sh && sudo bash /tmp/pre-bake-cleanup.sh --yes
# 세션 종료 후 바로:
AMI_ID=$(aws ec2 create-image --instance-id $WEB_ID --name lc-web-golden-$(date +%Y%m%d) \
  --tag-specifications "$(tag image lc-web-golden)" "$(tag snapshot lc-web-golden)" --query ImageId --output text)
aws ec2 wait image-available --image-ids $AMI_ID
```
`create-image` 는 기본값이 "재부팅함" 이다(`--no-reboot` 를 붙이지 않는다). 굽기 검증은 `ami/README.md` 6번 절: 사용자 데이터 없이 AMI 로 확인용 인스턴스를 띄워 서비스 상태를 보고 종료한다.
정리 스크립트는 에이전트를 멈추지만 enabled 는 그대로 둔다. `create-image` 기본값(재부팅함)이면 스냅샷 후 원본 인스턴스가 재부팅되면서 에이전트가 자동으로 다시 시작되고, cloud-init 첫 부팅 상태라 `install.sh` 도 다시 실행된다(앱 코드는 지워져 있어 `/up` 이 404, TG 에서 unhealthy → 재배포 필요). `--no-reboot` 로 만들었다면 에이전트가 멈춘 채라 `sudo systemctl start codedeploy-agent` 가 필요하다. AMI 로 띄운 새 인스턴스는 부팅 때 에이전트가 자동 시작한다.

## 12. ASG (수동 모드부터)
```bash
cat > /tmp/lc-lt.json <<EOF
{"ImageId":"$AMI_ID","InstanceType":"t3.small",
 "IamInstanceProfile":{"Name":"lc-ec2-profile"},
 "MetadataOptions":{"HttpTokens":"required","HttpPutResponseHopLimit":2,"HttpEndpoint":"enabled"},
 "BlockDeviceMappings":[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":10,"VolumeType":"gp3","Encrypted":true}}],
 "NetworkInterfaces":[{"DeviceIndex":0,"AssociatePublicIpAddress":true,"Groups":["$EC2_SG"]}],
 "TagSpecifications":[{"ResourceType":"instance","Tags":[
   {"Key":"Name","Value":"lcamtest-web"},{"Key":"Project","Value":"lcamtest"},{"Key":"Owner","Value":"sungho"},{"Key":"Ephemeral","Value":"true"}]}]}
EOF
aws ec2 create-launch-template --launch-template-name lc-web-lt --launch-template-data file:///tmp/lc-lt.json \
  --tag-specifications "$(tag launch-template lc-web-lt)" >/dev/null
aws autoscaling create-auto-scaling-group --auto-scaling-group-name lc-web-asg \
  --launch-template 'LaunchTemplateName=lc-web-lt,Version=$Latest' \
  --min-size 0 --max-size 3 --desired-capacity 0 --vpc-zone-identifier "$SUB_A,$SUB_C" \
  --target-group-arns $TG_ARN --health-check-type ELB --health-check-grace-period 300 \
  --tags Key=Project,Value=lcamtest,PropagateAtLaunch=true Key=Owner,Value=sungho,PropagateAtLaunch=true Key=Ephemeral,Value=true,PropagateAtLaunch=true
# 수동 모드
aws autoscaling suspend-processes --auto-scaling-group-name lc-web-asg --scaling-processes ReplaceUnhealthy Terminate AZRebalance ScheduledActions AlarmNotification
```
시작 템플릿에 **`AssociatePublicIpAddress: true`** 가 반드시 있어야 한다(NAT 가 없다). 네트워크 인터페이스를 정의했으므로 보안 그룹은 `NetworkInterfaces[].Groups` 안에 넣는다.

`lc-web` 배포 그룹을 ASG 기준으로 전환하고 태그 필터를 제거한다:
```bash
aws deploy update-deployment-group --application-name lc-app --current-deployment-group-name lc-web --auto-scaling-groups lc-web-asg
aws deploy get-deployment-group --application-name lc-app --deployment-group-name lc-web \
  --query 'deploymentGroupInfo.{asg:autoScalingGroups,tags:ec2TagSet,tagFilters:ec2TagFilters,outdated:outdatedInstancesStrategy}'
aws autoscaling describe-lifecycle-hooks --auto-scaling-group-name lc-web-asg      # CodeDeploy 가 만든 launch 훅 확인
```
태그 필터 제거는 `--ec2-tag-set` 에 빈 값을 주는 방식이 CLI 에서 되는지 확인하지 못했다(미검증). 위 `get-deployment-group` 결과에 `tags` 가 남아 있으면 콘솔(배포 그룹 편집 > 환경 구성)에서 태그를 제거한다.

투입과 확인:
```bash
aws autoscaling set-desired-capacity --auto-scaling-group-name lc-web-asg --desired-capacity 1
aws autoscaling describe-scaling-activities --auto-scaling-group-name lc-web-asg --max-items 5 --query 'Activities[].[StatusCode,Description,Cause]' --output text
aws deploy list-deployments --application-name lc-app --deployment-group-name lc-web --max-items 3 --query deployments --output text   # launch deployment 가 새로 생김
aws autoscaling set-desired-capacity --auto-scaling-group-name lc-web-asg --desired-capacity 2    # healthy 확인 후
```
시험 T5~T8 후 자동 복구 프로세스 해제, 마지막에 스케일 정책:
```bash
aws autoscaling resume-processes --auto-scaling-group-name lc-web-asg --scaling-processes ReplaceUnhealthy Terminate AZRebalance ScheduledActions AlarmNotification
aws autoscaling put-scaling-policy --auto-scaling-group-name lc-web-asg --policy-name lc-cpu50 --policy-type TargetTrackingScaling \
  --target-tracking-configuration '{"PredefinedMetricSpecification":{"PredefinedMetricType":"ASGAverageCPUUtilization"},"TargetValue":50.0}'
```
단독 Web 은 ASG 가 정상이면 종료: `aws ec2 terminate-instances --instance-ids $WEB_ID`.

## 13. 시험에서 쓰는 명령
```bash
# T8 인스턴스 종료 후 교체 (Terminate 프로세스가 중지돼 있으면 동작이 달라질 수 있어 결과를 기록)
aws autoscaling terminate-instance-in-auto-scaling-group --instance-id <id> --no-should-decrement-desired-capacity
# T11 한 AZ 인스턴스 중지
aws ec2 stop-instances --instance-ids <id>
# T4 복구 / 수동 CodeDeploy 롤백 (정상 SHA 의 zip 재배포)
aws deploy create-deployment --application-name lc-app --deployment-group-name lc-web \
  --s3-location bucket=lc-deploy-$ACCOUNT,key=deploy/<정상 SHA>.zip,bundleType=zip \
  --file-exists-behavior OVERWRITE --ignore-application-stop-failures --auto-rollback-configuration enabled=false
# 배포 중단 (자동 롤백 포함)
aws deploy stop-deployment --deployment-id $D --auto-rollback-enabled
# T15 zip 만료: 1일 수명 규칙 + 대상 zip 삭제 → 롤백/증설 시도 (끝나면 규칙 삭제로 원복)
aws s3api put-bucket-lifecycle-configuration --bucket lc-deploy-$ACCOUNT --lifecycle-configuration \
  '{"Rules":[{"ID":"expire-deploy","Status":"Enabled","Filter":{"Prefix":"deploy/"},"Expiration":{"Days":1}}]}'
aws s3 rm s3://lc-deploy-$ACCOUNT/deploy/<SHA>.zip
aws s3api delete-bucket-lifecycle --bucket lc-deploy-$ACCOUNT
# T12 /up 실패 (서버에서)    sudo touch /var/www/shared/FAULT_UP_500     / 복구: sudo rm /var/www/shared/FAULT_UP_500
```
비상 중단 3줄은 `TEST-GUIDE.md` 맨 아래.

## 14. 정리 (역순)
```bash
aws autoscaling delete-auto-scaling-group --auto-scaling-group-name lc-web-asg --force-delete
aws ec2 delete-launch-template --launch-template-name lc-web-lt
aws ec2 terminate-instances --instance-ids $WEB_ID $Q_ID $S_ID
aws elbv2 delete-load-balancer --load-balancer-arn $ALB_ARN       # 삭제 완료까지 1~2분 기다린 뒤 TG 삭제
aws elbv2 delete-target-group --target-group-arn $TG_ARN
for g in lc-web lc-queue lc-scheduler; do aws deploy delete-deployment-group --application-name lc-app --deployment-group-name $g; done
aws deploy delete-application --application-name lc-app
aws ec2 deregister-image --image-id $AMI_ID        # 연결된 스냅샷도 삭제: aws ec2 describe-snapshots --owner-ids self --filters Name=tag:Project,Values=lcamtest
aws s3 rm s3://lc-deploy-$ACCOUNT --recursive && aws s3api delete-bucket --bucket lc-deploy-$ACCOUNT
# VPC: 인스턴스/ALB 가 완전히 사라진 뒤
aws ec2 delete-security-group --group-id $EC2_SG; aws ec2 delete-security-group --group-id $ALB_SG
aws ec2 delete-vpc-endpoints --vpc-endpoint-ids $(aws ec2 describe-vpc-endpoints --filters Name=vpc-id,Values=$VPC --query 'VpcEndpoints[].VpcEndpointId' --output text)
for s in $SUB_A $SUB_C; do aws ec2 delete-subnet --subnet-id $s; done
aws ec2 delete-route-table --route-table-id $RT
aws ec2 detach-internet-gateway --internet-gateway-id $IGW --vpc-id $VPC && aws ec2 delete-internet-gateway --internet-gateway-id $IGW
aws ec2 delete-vpc --vpc-id $VPC
# IAM
aws iam remove-role-from-instance-profile --instance-profile-name lc-ec2-profile --role-name lc-ec2-role && aws iam delete-instance-profile --instance-profile-name lc-ec2-profile
aws iam detach-role-policy --role-name lc-ec2-role --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore; aws iam delete-role-policy --role-name lc-ec2-role --policy-name lc-ec2-inline; aws iam delete-role --role-name lc-ec2-role
aws iam detach-role-policy --role-name lc-codedeploy-role --policy-arn arn:aws:iam::aws:policy/service-role/AWSCodeDeployRole; aws iam delete-role --role-name lc-codedeploy-role
aws iam delete-role-policy --role-name lc-github-oidc-role --policy-name lc-github-deploy; aws iam delete-role --role-name lc-github-oidc-role
aws iam delete-open-id-connect-provider --open-id-connect-provider-arn arn:aws:iam::$ACCOUNT:oidc-provider/token.actions.githubusercontent.com   # 다른 용도로 안 쓸 때만
```
남은 것 확인: `aws resourcegroupstaggingapi get-resources --tag-filters Key=Project,Values=lcamtest --query 'ResourceTagMappingList[].ResourceARN'`

## 알려진 미검증
이 문서의 명령은 이 환경에서 실행해 보지 않았다. 처음 돌릴 때 특히 확인할 곳: 태그 헬퍼 `tag` 의 인용(zsh 에서 `${3:+,$3}` 포함), 배포 그룹의 태그 필터 제거(§12), 에이전트 2.x 로그 경로(§10), 삭제 순서에서 ENI/의존성 때문에 실패하는 경우(잠시 기다렸다 재시도).
