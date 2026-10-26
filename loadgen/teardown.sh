#!/bin/bash
# Terminates the load generator and deletes its security group and S3 bucket.
set -e
cd "$(dirname "$0")"
source .state
REGION=us-west-2
aws ec2 terminate-instances --region $REGION --instance-ids $INSTANCE >/dev/null
aws s3 rb s3://$BUCKET --force --region $REGION >/dev/null
aws ec2 wait instance-terminated --region $REGION --instance-ids $INSTANCE
aws ec2 delete-security-group --region $REGION --group-id $SG
rm .state
echo "load generator removed"
