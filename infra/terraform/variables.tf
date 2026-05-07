variable "aws_region" {
  description = "AWS region where the stack will be deployed."
  type        = string
  default     = "us-east-1"
}

variable "stack_name" {
  description = "Prefix used for Terraform-managed AWS resources."
  type        = string
  default     = "observability-business-case"
}

variable "resource_prefix" {
  description = "Optional general prefix added to all named AWS resources."
  type        = string
  default     = ""
}

variable "payment_failure_mode" {
  description = "Failure behavior for the payment simulator Lambda."
  type        = string
  default     = "none"

  validation {
    condition = contains([
      "none",
      "always_fail",
      "random_fail",
      "slow_response",
      "random_reject"
    ], var.payment_failure_mode)
    error_message = "payment_failure_mode must be one of: none, always_fail, random_fail, slow_response, random_reject."
  }
}
