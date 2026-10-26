#!/bin/bash
# Launches an EC2 t3.medium in us-west-2 with Locust installed, driven through Systems Manager (no SSH),
# plus an S3 bucket to bring results back. State goes in loadgen/.state.
set -e
cd "$(dirname "$0")"
REGION=us-west-2
VPC=$(aws ec2 describe-vpcs --region $REGION --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)
SG=$(aws ec2 create-security-group --region $REGION --group-name cs6650-loadgen-sg --description "Locust load generator (outbound only)" --vpc-id $VPC --query GroupId --output text)
AMI=$(aws ssm get-parameter --region $REGION --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 --query Parameter.Value --output text)
cat > /tmp/loadgen-userdata.sh <<'UD'
#!/bin/bash
dnf install -y python3.11
python3.11 -m venv /opt/venv
/opt/venv/bin/pip install --upgrade pip
/opt/venv/bin/pip install locust
ln -sf /opt/venv/bin/locust /usr/local/bin/locust
UD
ID=$(aws ec2 run-instances --region $REGION --image-id $AMI --instance-type t3.medium --security-group-ids $SG \
  --iam-instance-profile Name=LabInstanceProfile --user-data file:///tmp/loadgen-userdata.sh \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=cs6650-loadgen}]' \
  --query 'Instances[0].InstanceId' --output text)
BUCKET=cs6650-loadgen-$(aws sts get-caller-identity --query Account --output text)-$(date +%s)
aws s3 mb s3://$BUCKET --region $REGION >/dev/null
printf 'INSTANCE=%s\nSG=%s\nBUCKET=%s\n' $ID $SG $BUCKET > .state
echo "launched $ID; waiting for Systems Manager and Locust..."
until [ "$(aws ssm describe-instance-information --region $REGION --filters Key=InstanceIds,Values=$ID --query 'InstanceInformationList[0].PingStatus' --output text)" = Online ]; do sleep 10; done
CMD=$(aws ssm send-command --region $REGION --instance-ids $ID --document-name AWS-RunShellScript \
  --parameters '{"commands":["until command -v locust >/dev/null; do sleep 5; done; locust --version"],"executionTimeout":["900"]}' --query Command.CommandId --output text)
until S=$(aws ssm get-command-invocation --region $REGION --command-id $CMD --instance-id $ID --query Status --output text 2>/dev/null) && [[ "$S" =~ ^(Success|Failed|TimedOut)$ ]]; do sleep 5; done
aws ssm get-command-invocation --region $REGION --command-id $CMD --instance-id $ID --query StandardOutputContent --output text
