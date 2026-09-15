#!/bin/bash
STACKS=("net-dev")

if [ "$1" == "--nightly" ]; then
  echo "Nightly teardown: stopping tasks and dropping ALB + VPC endpoints..."

  TASKS=$(aws ecs list-tasks --cluster net-dev-cluster --profile sandbox --query 'taskArns[]' --output text)
  for task in $TASKS; do
    echo "Stopping task $task..."
    aws ecs stop-task --cluster net-dev-cluster --task "$task" --profile sandbox
  done

  aws cloudformation deploy --template-file 01-network-edge.yaml --stack-name net-dev \
    --parameter-overrides CreateVpcEndpoints=false CreateAlb=false --profile sandbox

  echo "Nightly teardown complete."
else
  echo "Full teardown: deleting all stacks in reverse order..."

  for (( idx=${#STACKS[@]}-1 ; idx>=0 ; idx-- )); do
    stack="${STACKS[$idx]}"
    echo "Deleting $stack..."
    aws cloudformation delete-stack --stack-name "$stack" --profile sandbox
    aws cloudformation wait stack-delete-complete --stack-name "$stack" --profile sandbox
    echo "$stack deleted."
  done
fi
