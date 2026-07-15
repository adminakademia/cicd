# Najnowsze AMI Ubuntu 24.04 (jak w poprzednich lekcjach):
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # oficjalne konto Canonical (Ubuntu)
 
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd*/ubuntu-noble-24.04-amd64-server-*"]
  }
 
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
 
  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}