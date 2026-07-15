output "instance_id" {
  description = "ID instancji EC2."
  value       = aws_instance.this.id
}