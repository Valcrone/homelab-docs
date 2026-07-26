output "zabbix_publisher_access_key_id" {
  value = aws_iam_access_key.zabbix_publisher_key.id
}

output "zabbix_publisher_secret_access_key" {
  value     = aws_iam_access_key.zabbix_publisher_key.secret
  sensitive = true
}

output "sns_topic_arn" {
  value = aws_sns_topic.zabbix_alerts.arn
}

output "s3_bucket_name" {
  value = aws_s3_bucket.wazuh_logs.id
}
