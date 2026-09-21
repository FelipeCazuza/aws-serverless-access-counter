data "archive_file" "lambda" {
  type             = "zip"
  output_file_mode = "0755"
  source_file      = "${path.module}/../lambda/bootstrap"
  output_path      = "${path.module}/../lambda/function.zip"
}

resource "aws_lambda_function" "counter" {
  function_name = local.lambda_function_name
  description   = "Serverless access counter written in Go."

  role             = aws_iam_role.lambda.arn
  runtime          = "provided.al2023"
  handler          = "bootstrap"
  architectures    = ["arm64"]
  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256

  memory_size = 128
  timeout     = 5

  environment {
    variables = {
      TABLE_NAME = aws_dynamodb_table.counter.name
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.lambda,
    aws_iam_role_policy.lambda_runtime
  ]
}
