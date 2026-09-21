variable "aws_region" {
  description = "AWS region used to provision the project resources."
  type        = string
  default     = "us-east-1"
}

variable "allowed_account_ids" {
  description = "Required account guard supplied by the SOPS scripts."
  type        = list(string)

  validation {
    condition     = length(var.allowed_account_ids) == 1 && alltrue([for id in var.allowed_account_ids : can(regex("^[0-9]{12}$", id))])
    error_message = "Supply exactly one AWS account ID with 12 digits."
  }
}
