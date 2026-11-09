resource "random_password" "db_master" {
  length  = 48
  special = false # Aurora rejects several punctuation characters in master passwords
}

# The Data API takes a secret ARN, so the password never appears in Lambda
# configuration, in the database, or in this repository. Terraform state holds
# it, which is why the production backend is encrypted.
resource "aws_secretsmanager_secret" "db_master" {
  name                    = "vrc/database/master"
  description             = "Aurora master credentials. Consumed by the RDS Data API by ARN."
  kms_key_id              = aws_kms_key.main.arn
  recovery_window_in_days = 30
}

resource "aws_secretsmanager_secret_version" "db_master" {
  secret_id = aws_secretsmanager_secret.db_master.id
  secret_string = jsonencode({
    username = "vrc_admin"
    password = random_password.db_master.result
  })
}

resource "aws_rds_cluster" "main" {
  cluster_identifier = "vrc-main"
  engine             = "aurora-postgresql"
  engine_mode        = "provisioned"
  # 16.4: minimum capacity 0 requires Aurora PostgreSQL 16.3 or later.
  engine_version = "16.4"
  database_name  = "vrc"

  master_username                     = "vrc_admin"
  manage_master_user_password         = null
  master_password                     = random_password.db_master.result
  iam_database_authentication_enabled = true

  # The architectural keystone: an HTTPS endpoint for SQL, so the Lambdas stay
  # out of the VPC and no NAT gateway is needed.
  enable_http_endpoint = true

  serverlessv2_scaling_configuration {
    min_capacity             = var.db_min_capacity
    max_capacity             = var.db_max_capacity
    seconds_until_auto_pause = var.seconds_until_auto_pause
  }

  db_subnet_group_name   = aws_db_subnet_group.db.name
  vpc_security_group_ids = [aws_security_group.db.id]

  storage_encrypted = true
  kms_key_id        = aws_kms_key.main.arn

  backup_retention_period      = 7
  preferred_backup_window      = "07:00-08:00"
  copy_tags_to_snapshot        = true
  deletion_protection          = true
  skip_final_snapshot          = false
  final_snapshot_identifier    = "vrc-main-final"
  apply_immediately            = false
  performance_insights_enabled = false # chargeable beyond 7 days; not needed at this size

  lifecycle {
    # Reservation data. An accidental replacement must fail the plan, not
    # destroy the cluster.
    prevent_destroy = true
  }
}

resource "aws_rds_cluster_instance" "writer" {
  identifier         = "vrc-main-writer"
  cluster_identifier = aws_rds_cluster.main.id
  instance_class     = "db.serverless"
  engine             = aws_rds_cluster.main.engine
  engine_version     = aws_rds_cluster.main.engine_version

  # No public access, and no reader instance: this is a single-writer workload.
  publicly_accessible = false
}

# An abandoned open transaction would both block concurrent bookings on the
# exclusion constraint and hold the cluster awake, so this is a correctness
# control and a cost control at once.
resource "aws_rds_cluster_parameter_group" "main" {
  name   = "vrc-main-pg16"
  family = "aurora-postgresql16"

  parameter {
    name  = "log_min_duration_statement"
    value = "500"
  }

  parameter {
    name  = "idle_in_transaction_session_timeout"
    value = "30000"
  }
}
