resource "aws_dynamodb_table" "counter" {
  name         = "${local.name_prefix}-counter"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "id"

  attribute {
    name = "id"
    type = "S"
  }

  deletion_protection_enabled = false
}
