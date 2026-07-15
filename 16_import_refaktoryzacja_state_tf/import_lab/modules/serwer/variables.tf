variable "ami_id" {
  type        = string
  description = "ID obrazu AMI dla instancji."
}
 
variable "instance_type" {
  type        = string
  description = "Typ instancji EC2."
}
 
variable "subnet_id" {
  type        = string
  description = "ID podsieci, w ktorej powstanie instancja."
}
 
variable "security_group_id" {
  type        = string
  description = "ID security group przypisywanej instancji."
}
 
variable "tags" {
  type        = map(string)
  description = "Tagi instancji."
  default     = {}
}