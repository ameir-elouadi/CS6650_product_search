#!/bin/bash
# Keeps targets/ecs.json listing every running task's public IP, so Prometheus scrapes each task
# as the service scales. Run from observability/ while the stack is up; stop with Ctrl-C.
CLUSTER=${CLUSTER:-CS6650-search-cluster}
SERVICE=${SERVICE:-CS6650-search}
mkdir -p targets
while true; do
  TASKS=$(aws ecs list-tasks --cluster $CLUSTER --service-name $SERVICE --desired-status RUNNING --query 'taskArns' --output text)
  ENIS=""
  [ -n "$TASKS" ] && ENIS=$(aws ecs describe-tasks --cluster $CLUSTER --tasks $TASKS \
    --query "tasks[?lastStatus=='RUNNING'].attachments[].details[?name=='networkInterfaceId'].value[]" --output text)
  IPS=""
  [ -n "$ENIS" ] && IPS=$(aws ec2 describe-network-interfaces --network-interface-ids $ENIS \
    --query 'NetworkInterfaces[].Association.PublicIp' --output text)
  python3 -c 'import json,sys; print(json.dumps([{"targets": [ip + ":8080" for ip in sys.argv[1:]]}]))' $IPS > targets/ecs.json.tmp
  mv targets/ecs.json.tmp targets/ecs.json
  echo "$(date -u +%H:%M:%S) scraping: ${IPS:-none}"
  sleep 15
done
