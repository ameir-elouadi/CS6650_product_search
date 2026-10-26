#!/bin/bash
# run.sh <name> <locustfile> <locust args...>
# Runs Locust headless on the load generator and copies the CSVs, HTML report and console summary
# to results/part3/data/<name>/. Example:
#   loadgen/run.sh core locust/search_locustfile.py -u 20 -r 20 -t 20m --host http://<alb-dns>
set -e
cd "$(dirname "$0")/.."
source loadgen/.state
REGION=us-west-2
NAME=$1; LOCUSTFILE=$2; shift 2
B64() { base64 < "$1" | tr -d '\n'; }
# The search user class lives in search_locustfile.py; shape files import it
REMOTE="set -e; mkdir -p /opt/run/$NAME && cd /opt/run/$NAME
echo $(B64 locust/search_locustfile.py) | base64 -d > search_locustfile.py
echo $(B64 $LOCUSTFILE) | base64 -d > locustfile.py
date -u +%Y-%m-%dT%H:%M:%SZ > start.txt
locust -f locustfile.py --headless $* --csv $NAME --html $NAME.html --only-summary > summary.txt 2>&1 || true
date -u +%Y-%m-%dT%H:%M:%SZ > end.txt
rm -f locustfile.py search_locustfile.py; rm -rf __pycache__
aws s3 cp --recursive /opt/run/$NAME s3://$BUCKET/$NAME/ --quiet
cat start.txt end.txt; grep -E '^ *(Type|GET|Aggregated)' summary.txt"
PARAMS=$(python3 -c 'import json,sys; print(json.dumps({"commands":[sys.argv[1]],"executionTimeout":["7200"]}))' "$REMOTE")
CMD=$(aws ssm send-command --region $REGION --instance-ids $INSTANCE --document-name AWS-RunShellScript --parameters "$PARAMS" --query Command.CommandId --output text)
echo "$(date -u +%H:%M:%S) started $NAME ($CMD)"
until S=$(aws ssm get-command-invocation --region $REGION --command-id $CMD --instance-id $INSTANCE --query Status --output text 2>/dev/null) && [[ "$S" =~ ^(Success|Failed|TimedOut|Cancelled)$ ]]; do sleep 10; done
aws ssm get-command-invocation --region $REGION --command-id $CMD --instance-id $INSTANCE --query '[StandardOutputContent,StandardErrorContent]' --output text
mkdir -p results/part3/data/$NAME
aws s3 cp --recursive s3://$BUCKET/$NAME/ results/part3/data/$NAME/ --quiet
ls results/part3/data/$NAME
