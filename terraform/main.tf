resource "random_id" "bucket_suffix" {
  byte_length = 4
}

resource "aws_s3_bucket" "wazuh_logs" {
  bucket = "rabih-homelab-wazuh-logs-${random_id.bucket_suffix.hex}"

  tags = {
    Project = "homelab"
    Purpose = "wazuh-log-archive"
  }
}

resource "aws_s3_bucket_public_access_block" "wazuh_logs" {
  bucket = aws_s3_bucket.wazuh_logs.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_sns_topic" "zabbix_alerts" {
  name = "homelab-zabbix-alerts"

  tags = {
    Project = "homelab"
    Purpose = "zabbix-alert-notifications"
  }
}

resource "aws_iam_role" "lambda_archive_role" {
  name = "homelab-lambda-archive-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })

  tags = {
    Project = "homelab"
  }
}

resource "aws_iam_role_policy" "lambda_archive_policy" {
  name = "homelab-lambda-archive-policy"
  role = aws_iam_role.lambda_archive_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject"
        ]
        Resource = "${aws_s3_bucket.wazuh_logs.arn}/*"
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:*:*:*"
      }
    ]
  })
}

data "archive_file" "lambda_zip" {
  type        = "zip"
  source_dir  = "${path.module}/lambda"
  output_path = "${path.module}/lambda_archive.zip"
}

resource "aws_lambda_function" "archive_alerts" {
  function_name    = "homelab-archive-zabbix-alerts"
  role             = aws_iam_role.lambda_archive_role.arn
  handler          = "lambda_function.handler"
  runtime          = "python3.12"
  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  timeout          = 30

  environment {
    variables = {
      BUCKET_NAME = aws_s3_bucket.wazuh_logs.id
    }
  }

  tags = {
    Project = "homelab"
  }
}

resource "aws_sns_topic_subscription" "lambda_subscription" {
  topic_arn = aws_sns_topic.zabbix_alerts.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.archive_alerts.arn
}

resource "aws_lambda_permission" "allow_sns" {
  statement_id  = "AllowSNSInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.archive_alerts.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.zabbix_alerts.arn
}

resource "aws_iam_user" "zabbix_publisher" {
  name = "zabbix-sns-publisher"

  tags = {
    Project = "homelab"
  }
}

resource "aws_iam_user_policy" "zabbix_publish_policy" {
  name = "homelab-zabbix-sns-publish"
  user = aws_iam_user.zabbix_publisher.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "sns:Publish"
        Resource = aws_sns_topic.zabbix_alerts.arn
      }
    ]
  })
}

resource "aws_iam_access_key" "zabbix_publisher_key" {
  user = aws_iam_user.zabbix_publisher.name
}
