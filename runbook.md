### day 1
The following command 'aws sts get-caller-identity --profile sandbox' returned the Admin role's unique id with combined with session name. The account number and currenkt session was also present.

### day 2
1. Bootstrap -> network/edge -> data -> compute
2. Bootstrap provides the S3 bucket and IAM role that is needed without them you cannot create resources. RDS and ElasticCache have to attach to subnets and security groups, which only exist in a VPC. Data is needed for ECS as to connect to the database ECS tasks need to read them from Secrets manager which exist after teh data layer creates them.
3. Bootstrap: ECR, Network/Edge: VPC, Data: RDS, Compute: ECS cluster