terraform {
  required_version = ">= 1.6.0"

  backend "s3" {}

  required_providers {
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.7"
    }
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

data "archive_file" "lambda_bundle" {
  type             = "zip"
  source_dir       = "${path.module}/../../build/lambda"
  output_path      = "${path.module}/../../build/order-processing-lambda.zip"
  output_file_mode = "0666"
}

locals {
  normalized_resource_prefix      = trim(var.resource_prefix, "- ")
  name_prefix                     = local.normalized_resource_prefix != "" ? "${local.normalized_resource_prefix}-${var.stack_name}" : var.stack_name
  orders_table_name               = "${local.name_prefix}-orders"
  create_order_function_name      = "${local.name_prefix}-create-order"
  get_order_function_name         = "${local.name_prefix}-get-order"
  payment_simulator_function_name = "${local.name_prefix}-payment-simulator"
  order_processor_function_name   = "${local.name_prefix}-order-processor"
  event_bus_arn                   = "arn:${data.aws_partition.current.partition}:events:${var.aws_region}:${data.aws_caller_identity.current.account_id}:event-bus/default"
}

resource "aws_dynamodb_table" "orders" {
  name         = local.orders_table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "orderId"

  attribute {
    name = "orderId"
    type = "S"
  }
}

resource "aws_apigatewayv2_api" "orders" {
  name          = "${local.name_prefix}-http-api"
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.orders.id
  name        = "$default"
  auto_deploy = true
}

data "aws_iam_policy_document" "lambda_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "create_order" {
  name               = "${local.name_prefix}-create-order-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
}

resource "aws_iam_role" "get_order" {
  name               = "${local.name_prefix}-get-order-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
}

resource "aws_iam_role" "payment_simulator" {
  name               = "${local.name_prefix}-payment-simulator-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
}

resource "aws_iam_role" "order_processor" {
  name               = "${local.name_prefix}-order-processor-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
}

resource "aws_iam_role_policy_attachment" "create_order_logs" {
  role       = aws_iam_role.create_order.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "get_order_logs" {
  role       = aws_iam_role.get_order.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "payment_simulator_logs" {
  role       = aws_iam_role.payment_simulator.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "order_processor_logs" {
  role       = aws_iam_role.order_processor.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "aws_iam_policy_document" "create_order" {
  statement {
    actions = [
      "dynamodb:PutItem",
      "dynamodb:UpdateItem"
    ]
    resources = [aws_dynamodb_table.orders.arn]
  }

  statement {
    actions   = ["events:PutEvents"]
    resources = [local.event_bus_arn]
  }
}

resource "aws_iam_role_policy" "create_order" {
  name   = "${local.name_prefix}-create-order-policy"
  role   = aws_iam_role.create_order.id
  policy = data.aws_iam_policy_document.create_order.json
}

data "aws_iam_policy_document" "get_order" {
  statement {
    actions   = ["dynamodb:GetItem"]
    resources = [aws_dynamodb_table.orders.arn]
  }
}

resource "aws_iam_role_policy" "get_order" {
  name   = "${local.name_prefix}-get-order-policy"
  role   = aws_iam_role.get_order.id
  policy = data.aws_iam_policy_document.get_order.json
}

data "aws_iam_policy_document" "order_processor" {
  statement {
    actions = [
      "dynamodb:GetItem",
      "dynamodb:UpdateItem"
    ]
    resources = [aws_dynamodb_table.orders.arn]
  }

  statement {
    actions   = ["lambda:InvokeFunction"]
    resources = [aws_lambda_function.payment_simulator.arn]
  }
}

resource "aws_iam_role_policy" "order_processor" {
  name   = "${local.name_prefix}-order-processor-policy"
  role   = aws_iam_role.order_processor.id
  policy = data.aws_iam_policy_document.order_processor.json
}

resource "aws_lambda_function" "create_order" {
  function_name    = local.create_order_function_name
  role             = aws_iam_role.create_order.arn
  runtime          = "nodejs20.x"
  handler          = "src/order-api/create-order.handler"
  filename         = data.archive_file.lambda_bundle.output_path
  source_code_hash = data.archive_file.lambda_bundle.output_base64sha256
  timeout          = 10
  memory_size      = 256

  environment {
    variables = {
      ORDERS_TABLE_NAME = aws_dynamodb_table.orders.name
      EVENT_BUS_NAME    = "default"
      LOG_LEVEL         = "INFO"
    }
  }

  depends_on = [aws_iam_role_policy_attachment.create_order_logs]
}

resource "aws_lambda_function" "get_order" {
  function_name    = local.get_order_function_name
  role             = aws_iam_role.get_order.arn
  runtime          = "nodejs20.x"
  handler          = "src/order-api/get-order.handler"
  filename         = data.archive_file.lambda_bundle.output_path
  source_code_hash = data.archive_file.lambda_bundle.output_base64sha256
  timeout          = 10
  memory_size      = 256

  environment {
    variables = {
      ORDERS_TABLE_NAME = aws_dynamodb_table.orders.name
      EVENT_BUS_NAME    = "default"
      LOG_LEVEL         = "INFO"
    }
  }

  depends_on = [aws_iam_role_policy_attachment.get_order_logs]
}

resource "aws_lambda_function" "payment_simulator" {
  function_name    = local.payment_simulator_function_name
  role             = aws_iam_role.payment_simulator.arn
  runtime          = "nodejs20.x"
  handler          = "src/payment-simulator/process-payment.handler"
  filename         = data.archive_file.lambda_bundle.output_path
  source_code_hash = data.archive_file.lambda_bundle.output_base64sha256
  timeout          = 15
  memory_size      = 256

  environment {
    variables = {
      ORDERS_TABLE_NAME    = aws_dynamodb_table.orders.name
      EVENT_BUS_NAME       = "default"
      LOG_LEVEL            = "INFO"
      PAYMENT_FAILURE_MODE = var.payment_failure_mode
    }
  }

  depends_on = [aws_iam_role_policy_attachment.payment_simulator_logs]
}

resource "aws_lambda_function" "order_processor" {
  function_name    = local.order_processor_function_name
  role             = aws_iam_role.order_processor.arn
  runtime          = "nodejs20.x"
  handler          = "src/order-processor/process-order-created.handler"
  filename         = data.archive_file.lambda_bundle.output_path
  source_code_hash = data.archive_file.lambda_bundle.output_base64sha256
  timeout          = 10
  memory_size      = 256

  environment {
    variables = {
      ORDERS_TABLE_NAME               = aws_dynamodb_table.orders.name
      EVENT_BUS_NAME                  = "default"
      LOG_LEVEL                       = "INFO"
      PAYMENT_SIMULATOR_FUNCTION_NAME = aws_lambda_function.payment_simulator.function_name
    }
  }

  depends_on = [
    aws_iam_role_policy.order_processor,
    aws_iam_role_policy_attachment.order_processor_logs
  ]
}

resource "aws_apigatewayv2_integration" "create_order" {
  api_id                 = aws_apigatewayv2_api.orders.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.create_order.invoke_arn
  integration_method     = "POST"
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_integration" "get_order" {
  api_id                 = aws_apigatewayv2_api.orders.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.get_order.invoke_arn
  integration_method     = "POST"
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "create_order" {
  api_id    = aws_apigatewayv2_api.orders.id
  route_key = "POST /orders"
  target    = "integrations/${aws_apigatewayv2_integration.create_order.id}"
}

resource "aws_apigatewayv2_route" "get_order" {
  api_id    = aws_apigatewayv2_api.orders.id
  route_key = "GET /orders/{orderId}"
  target    = "integrations/${aws_apigatewayv2_integration.get_order.id}"
}

resource "aws_lambda_permission" "allow_api_gateway_create_order" {
  statement_id  = "AllowHttpApiInvokeCreateOrder"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.create_order.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.orders.execution_arn}/*/*"
}

resource "aws_lambda_permission" "allow_api_gateway_get_order" {
  statement_id  = "AllowHttpApiInvokeGetOrder"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.get_order.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.orders.execution_arn}/*/*"
}

resource "aws_cloudwatch_event_rule" "order_created" {
  name = "${local.name_prefix}-order-created"

  event_pattern = jsonencode({
    source        = ["workshop.orders"]
    "detail-type" = ["OrderCreated"]
  })
}

resource "aws_cloudwatch_event_target" "order_processor" {
  rule      = aws_cloudwatch_event_rule.order_created.name
  target_id = "OrderProcessorFunction"
  arn       = aws_lambda_function.order_processor.arn
}

resource "aws_lambda_permission" "allow_eventbridge_order_processor" {
  statement_id  = "AllowEventBridgeInvokeOrderProcessor"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.order_processor.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.order_created.arn
}
