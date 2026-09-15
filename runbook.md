### day 1
The following command 'aws sts get-caller-identity --profile sandbox' returned the Admin role's unique id with combined with session name. The account number and currenkt session was also present.

### day 2
1. Bootstrap -> network/edge -> data -> compute
2. Bootstrap provides the S3 bucket and IAM role that is needed without them you cannot create resources. RDS and ElasticCache have to attach to subnets and security groups, which only exist in a VPC. Data is needed for ECS as to connect to the database ECS tasks need to read them from Secrets manager which exist after teh data layer creates them.
3. Bootstrap: ECR, Network/Edge: VPC, Data: RDS, Compute: ECS cluster

### day 3
2. AWS::ECS::Service
3. Bootstrap: AWS::S3::Bucket, AWS::IAM::Role, AWS::IAM::Group, AWS::IAM::User, AWS::ECR::Repository, AWS::ECR::PublicRepository
Network/Edge: AWS::EC2::VPC, AWS::EC2::Subnet, AWS::EC2::RouteTable, AWS::WAFv2::WebACL, AWS::Route53::DNSSEC
Data: AWS::RDS::DBCluster AWS::SecretsManager::Secret, AWS::SecretsManager::RotationSchedule, AWS::RDS::DBInstance, AWS::ElastiCache::CacheCluster
Compute: AWS::ECS::TaskSet, AWS::ECS::Service, AWS::ECS::Cluster, AWS::ECS::TaskDefinition
4. AWS::S3::Bucket requires nothing
AWS::IAM::Role requires AssumeRolePolicyDocument only.
AWS::EC2::VPC requires nothing.
AWS::RDS::DBCluster requires nothing.
AWS::ECS::Cluster requires nothing.

### day 4
Client (internet)
   |
   | :443 HTTPS   <-- the ONLY arrow exposed to the public internet
   v
┌─────────────── PUBLIC SUBNET ───────────────┐
│  [Route 53]  — DNS only: resolves the domain │
│       |         to the ALB's DNS name        │
│       | :443                                 │
│       v                                      │
│  [ALB]  — HTTPS listener, terminates TLS     │
│  (ACM cert lives here)                       │
│       |                                      │
│  [WAFv2 Web ACL attached to the ALB]         │
│  — inspects the request, blocks bad ones     │
│  BEFORE it reaches a target                  │
│       |                                      │
│  [Target Group] — routing list, forwards     │
│  healthy requests to registered tasks        │
└───────|───────────────────────────────────────┘
        | :8080 (app port)
        v
┌─────────────── PRIVATE SUBNET ──────────────┐
│  [ECS/Fargate task: api]  <- this IS snip    │
│       |                  \                   │
│       | :5432              | :6379           │
│       v                    v                 │
│  [RDS Postgres]      [ElastiCache Redis]     │
│  (links table)        (cached GET /:code)    │
└───────────────────────────────────────────────┘

Scheduled job — NOT on the request path, no arrow from ALB:

[EventBridge Scheduler] --cron--> [ECS/Fargate task: job] (private subnet)
                                          |
                                          | :5432
                                          v
                                    [RDS Postgres]
                        (rolls up click_count, deletes expired links)

### day 5
commit -> CircleCI (checks/tests) -> docker build -> push image -> ECR
                                                                    |
                                                                    (shared artifact, tagged by commit SHA)

(deploy to dev) CFN template -> S3 -> Step Functions -> Cloud Formation -> ECS update (dev)
                                |
                            manual approval
                                | 
(deploy to stage) CFN template -> S3 -> Step Functions -> Cloud Formation -> ECS update (stage)

2. Manual approval gate is inside CircleCI workflow after deb job suceeds before teh stage deploy can start.
3. credentials needed when pusing to ECR, CFN to S3, executing step function, CloudFormation and ECS service. CircleCI needs IAM role for every step. It needs to touch aws once it reaches the push to ECR.
4. Failsure show up in CI log, S3, CFN events and ECS Events.



### Week 2


### day 1
2. Since we end in /16 then we have 2^(32-16) ip addresses.
3. To split into four blocks
10.0.0.0/24, 10.0.1.0/24, 10.0.2.0/24, 10.0.3.0/24
4. Two are public two are private

10.0.0.0/24 (public, us-east-1a) 
10.0.1.0/24 (public, us-east-1b) 
10.0.2.0/24 (private, us-east-1a)
10.0.3.0/24 (private, us-east-1b)
5. Each block has 251 usable ip addresses because every block has network address, VPC router, DNS, future use, broadcast set aside.


### day 3
6. The Application load balancer security group is open to the internet to receive requests from any ip address. The task security group only needs to information from the previous security group as the information should go through the first security group to ensure only one listens to the internet.
7. Ran a single nginx Fargate task in the public subnet (assignPublicIp=ENABLED, since there's no NAT/VPC endpoints yet) and registered its private IP with the target group on port 80. Kept this **out of CloudFormation** on purpose — task defs/services/execution roles aren't taught until weeks 3/5, and this task is just a borrowed prop, not part of the layered stack. Everything below is plain CLI/JSON, reran cleanly, and is what day 4 restores to before each break:
   - `aws ecs create-cluster --cluster-name net-dev-cluster`
   - `aws logs create-log-group --log-group-name /ecs/net-dev-nginx` + `put-retention-policy --retention-in-days 3` (note: Git Bash on Windows mangles a leading `/` in args as a path — prefix with `MSYS_NO_PATHCONV=1`)
   - `nginx-task-def.json` (repo root) registered with `aws ecs register-task-definition --cli-input-json file://nginx-task-def.json` — reuses the existing `ecsTaskExecutionRole` (trusts `ecs-tasks.amazonaws.com`, has `AmazonECSTaskExecutionRolePolicy`), not redeclared
   - `aws ecs run-task --cluster net-dev-cluster --task-definition net-dev-nginx --launch-type FARGATE --network-configuration "awsvpcConfiguration={subnets=[<PublicSubnetOne>],securityGroups=[<TaskSecurityGroup>],assignPublicIp=ENABLED}"`
   - get the task's ENI private IP (`describe-tasks` -> `describe-network-interfaces`), then `aws elbv2 register-targets --target-group-arn <tg-arn> --targets Id=<private-ip>,Port=80` — standalone `run-task` doesn't auto-register like an `AWS::ECS::Service` with `LoadBalancers` would.
   Check: `curl http://<alb-dns>` returned `200` and the nginx welcome page — first end-to-end request path (ALB -> target group -> Fargate task) working. (First curl right after registering returned `503` — target health checks take ~2.5 min of passing checks before a target flips to `healthy`; not a real fault.)


### day 4
4. Delted ALB→task rule from the task SG. This caused the fargate server to 503 because it couldn't connect. Fix add rule to the security group. Prevent by ensuring each task has specific inbound rule to allow trafic from ALB SG.

Point the target group to the wrong port. This caused a health-check failure 503. Point task to right target group. Prevent by ensuring target group ports mathces listening port.

Cannot pull container error that shows up in ECS stopped-task reason. Task placed in a private subnet with no way to be reached. Add missing egress path to NAT Gateway or VPC interface endpoints. Prevent by ensuring any task that needs to pull from ECR needs an explicit egress path. 

5. The root cause was taht ht e private subnet has no access to the internet since ECR is  a public endpoint it has no way to reach it. Solution use a NAT Gateway or VPC  endpoint.
NAT Gateway .045/hr + data processing
Interface endpoints .01/hr for each AZ.