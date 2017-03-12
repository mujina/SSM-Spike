variable "region"           { default = "eu-west-1" }
variable "profile"          { default = "redacted" }
variable "account"          { default = "redacted" }
variable "ami_id"           { default = "ami-70edb016" }
variable "vpc_id"           { default = "redacted"}
variable "subnet_id"        { default = "redacted" }
variable "key_name"         { default = "redacted" }
variable "instance_type"    { default = "t2.micro" }
variable "ticket_id"        { default = "redacted" }
variable "root_volume_size" { default = "10" }
variable "root_volume_type" { default = "standard" }
variable "ssm_doc_name"     { default = "get_versions" }
variable "ssm_policy_arn"   { default = "arn:aws:iam::aws:policy/service-role/AmazonEC2RoleforSSM" }
variable "s3_output_bucket" { default = "pugme.ssm.dev" } 
variable "s3_output_prefix" { } 
variable "environments"     { default = [ "Dev", "Test" ] }

## Provider

provider "aws" {
  profile = "${var.profile}"
  region = "${var.region}"
}

## Data elements 

data "aws_ami" "amazon_linux" {
  most_recent = true
  filter {
    name = "name"
    values = ["amzn-ami*"]
  }
  filter {
    name = "virtualization-type"
    values = ["hvm"]
  }
  filter { 
    name = "architecture"
    values = ["x86_64"]
  }
  filter { 
    name = "root-device-type"
    values = ["ebs"]
  }
  filter { 
    name = "block-device-mapping.volume-type"
    values = ["standard"]
  }
  owners = ["137112412989"] # Amazon
}

data "template_file" "user_data" {
  template = "${file("${path.module}/base.sh.tpl")}"
}

## IAM policies

resource "aws_iam_role" "ssm_role" {
    name = "ssm_role"
    assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Effect": "Allow",
      "Sid": ""
    }
  ]
}
EOF
}

resource "aws_iam_instance_profile" "ssm_instance_profile" {
    name = "ssm_instance_profile"
    roles = ["${aws_iam_role.ssm_role.name}"]
}

resource "aws_iam_role_policy_attachment" "ssm_role_instance_policy" {
    role = "${aws_iam_role.ssm_role.name}"
    policy_arn = "${var.ssm_policy_arn}"
}


## Security Groups

resource "aws_security_group" "sg_1" {
  lifecycle {
    create_before_destroy = true
  }

  description = "sg-${var.ticket_id}"
  vpc_id      = "${var.vpc_id}"
}

resource "aws_security_group_rule" "sgr_1" {
  type              = "ingress"
  from_port         = "22"
  to_port           = "22"
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = "${aws_security_group.sg_1.id}"
}

resource "aws_security_group_rule" "sgr_2" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = "${aws_security_group.sg_1.id}"
}


## SSM Document & Associations
resource "aws_ssm_document" "get_versions" {
  name    = "${var.ssm_doc_name}"
  document_type = "Command"

/*
  permissions = { 
    type        = "Share"
    account_ids = "all"
  }
*/

  content = <<DOC
  {
    "schemaVersion": "1.2",
    "description": "Run uptime",
    "parameters": { 

    },
    "runtimeConfig": {
      "aws:runShellScript": {
        "properties": [
          {
            "runCommand": [ "grep Version /etc/pugme-base/manifest | cut -c 10-" ],
            "workingDirectory": "/tmp",
            "timeoutSeconds": 10
          }
        ]
      }
    }
  }
DOC
}

/* No support for parameters which require map depth > 1
resource "aws_ssm_association" "ssm_get_versions" {
  name        = "${var.ssm_doc_name}"
  instance_id = "${aws_instance.ssmtest1.id}"
}

# Run this instead for now ...
aws --profile redacted ssm create-association --name get_versions \
    --schedule-expression "cron(0 0/30 * 1/1 * ? *)" --targets "Key=tag:Environment,Values=Dev" \
    --output-location "S3Location={OutputS3Region=eu-west-1,OutputS3BucketName=pugme.ssm.dev,OutputS3KeyPrefix=commands}"

*/

## S3 Bucket
/*
resource "aws_s3_bucket" "ssm_output" {
    bucket = "${var.s3_output_bucket}"
    acl = "private"
    force_destroy = "true"
}
*/

resource "aws_instance" "ssmtest1" {
  ami                         = "${data.aws_ami.amazon_linux.id}"
  count                       = 2
  instance_type               = "${var.instance_type}"
  ebs_optimized               = "false"
  key_name                    = "${var.key_name}"
  monitoring                  = "false"
  user_data                   = "${data.template_file.user_data.rendered}"
  vpc_security_group_ids      = [ "${aws_security_group.sg_1.id}" ]
  subnet_id                   = "${var.subnet_id}"
  associate_public_ip_address = "true"
  iam_instance_profile        = "${aws_iam_instance_profile.ssm_instance_profile.id}"

  root_block_device = {
    volume_type           = "${var.root_volume_type}"
    volume_size           = "${var.root_volume_size}"
    delete_on_termination = "true"
  }

  tags {
    Environment = "${ var.environments[count.index] }"
  }
}
