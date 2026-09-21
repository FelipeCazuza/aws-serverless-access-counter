output "aws_region" {
  description = "AWS region used by the project."
  value       = var.aws_region
}

output "dynamodb_table_name" {
  description = "DynamoDB counter table name."
  value       = aws_dynamodb_table.counter.name
}

output "lambda_function_name" {
  description = "Lambda function name."
  value       = aws_lambda_function.counter.function_name
}

output "hit_url" {
  description = "POST endpoint that increments and returns the counter."
  value       = "${aws_apigatewayv2_api.counter.api_endpoint}/hit"
}

output "cloudwatch_log_group" {
  description = "CloudWatch Log Group used by the Lambda."
  value       = aws_cloudwatch_log_group.lambda.name
}

data "aws_caller_identity" "current" {}

output "aws_account_id" {
  description = "Authenticated AWS account ID."
  value       = data.aws_caller_identity.current.account_id
}
