variable "repository_name" {
  description = "ECR repository name, such as igilro-dev/server."
  type        = string
}

variable "tags" {
  description = "Common resource tags."
  type        = map(string)
  default     = {}
}
