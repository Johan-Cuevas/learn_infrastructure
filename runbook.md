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