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
