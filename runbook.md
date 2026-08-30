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