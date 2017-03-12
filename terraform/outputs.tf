output "instance_public_dns" {
  value = "${aws_instance.ssmtest1.public_dns}"
}

output "instance_id" {
  value = "${aws_instance.ssmtest1.id}"
}
