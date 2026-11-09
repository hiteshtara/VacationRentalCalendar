resource "random_password" "db_master" {
  length  = 48
  special = false # Aurora rejects several punctuation characters in master passwords
}

# The Data API takes a secret ARN, so the password never appears in Lambda
# configuration, in the database, or in this repository. Terraform state holds
# it, which is why the production backend is encrypted.
resource "aws_secretsmanager_secret" "db_master" {
  name                    = "${local.prefix}/database/master"
  description             = "Aurora master credentials. Consumed by the RDS Data API by ARN."
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
  cluster_identifier = "${local.prefix}-main"
  engine             = "aurora-postgresql"
  engine_mode        = "provisioned"
  # Verified against `aws rds describe-db-engine-versions` in us-east-1 on
  # 2026-11-09, not taken from documentation: the 16 line now starts at 16.8,
  # and 16.4 -- which an earlier revision of this file pinned -- no longer
  # exists. An apply would have failed.
  #
  # 16.15 is the current 16.x release and clears both floors: minimum capacity
  # 0 ACU needs >= 16.3, and the RDS Data API needs >= 15.3 on the 15 line and
  # any 16.x.
  engine_version = "16.15"
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

  backup_retention_period = local.is_production ? 7 : 1
  preferred_backup_window = "07:00-08:00"
  copy_tags_to_snapshot   = true
  # Production is protected at the AWS level: `terraform destroy` fails against
  # deletion_protection until someone deliberately flips it, which is two
  # explicit steps rather than one command.
  #
  # Staging is destroyable on purpose. A staging environment that cannot be
  # torn down is a liability, not a safety feature -- it becomes a permanent
  # bill and a permanent attack surface. The Terraform-level `prevent_destroy`
  # that used to sit here is gone for the same reason: it cannot be made
  # conditional, so it would have blocked every legitimate staging teardown.
  deletion_protection          = local.is_production
  skip_final_snapshot          = !local.is_production
  final_snapshot_identifier    = "${local.prefix}-main-final"
  apply_immediately            = false
  performance_insights_enabled = false # chargeable beyond 7 days; not needed at this size

  lifecycle {
    # Reservation data. An accidental replacement must fail the plan, not
    # destroy the cluster.
    prevent_destroy = true
  }
}

resource "aws_rds_cluster_instance" "writer" {
  identifier         = "${local.prefix}-main-writer"
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
# The application never connects as the master account. This secret holds the
# restricted `vrc_runtime` login created by migration 003, which has no DDL
# rights, cannot rewrite the audit trail, and cannot delete source
# observations. The Data API is given THIS ARN, not the master one.
#
# No secret_version resource: the password is generated and written once, out
# of band, so it never enters Terraform state.
resource "aws_secretsmanager_secret" "db_runtime" {
  name                    = "${local.prefix}/database/runtime"
  description             = "Restricted vrc_runtime login. Used by every Lambda via the Data API."
  recovery_window_in_days = 30
}

resource "aws_rds_cluster_parameter_group" "main" {
  name   = "${local.prefix}-main-pg16"
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
