resource "aws_apigatewayv2_api" "counter" {
  name          = "${local.name_prefix}-api"
  protocol_type = "HTTP"

}

resource "aws_apigatewayv2_integration" "counter" {
  api_id = aws_apigatewayv2_api.counter.id

  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.counter.invoke_arn
  integration_method     = "POST"
  payload_format_version = "2.0"
  timeout_milliseconds   = 5000
}

resource "aws_apigatewayv2_route" "hit" {
  api_id = aws_apigatewayv2_api.counter.id

  route_key = "POST /hit"
  target    = "integrations/${aws_apigatewayv2_integration.counter.id}"
}

resource "aws_apigatewayv2_stage" "default" {
  api_id = aws_apigatewayv2_api.counter.id

  name        = "$default"
  auto_deploy = true
}

resource "aws_lambda_permission" "api_gateway" {
  statement_id  = "AllowExecutionFromAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.counter.function_name
  principal     = "apigateway.amazonaws.com"

  source_arn = "${aws_apigatewayv2_api.counter.execution_arn}/*/POST/hit"
}
