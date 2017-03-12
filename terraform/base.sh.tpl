#!/bin/bash
set -x
exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1

echo "==[Create dummy file to match with Run Command]=="
mkdir /etc/pugme-base
echo "Version: 1.0.0" > /etc/pugme-base/manifest

echo "==[Installing Amazon SSM Agent RPM]=="
cd /tmp
curl https://s3.amazonaws.com/ec2-downloads-windows/SSMAgent/latest/linux_amd64/amazon-ssm-agent.rpm -o amazon-ssm-agent.rpm 
/usr/bin/yum install -y amazon-ssm-agent.rpm
echo "==[Starting amazon ssm-agent]=="
start amazon-ssm-agent
