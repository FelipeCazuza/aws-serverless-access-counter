locals {
  name_prefix          = "serverless-access-counter-lab"
  lambda_function_name = "${local.name_prefix}-counter"

  common_tags = {
    Project     = "serverless-access-counter"
    Environment = "lab"
    ManagedBy   = "Terraform"
    Repository  = "aws-serverless-access-counter"
  }
}
