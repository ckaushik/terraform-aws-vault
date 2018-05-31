# Create a new load balancer

data "aws_elb_service_account" "main" {}

resource "aws_s3_bucket" "access_logs" {
  bucket_prefix = "${var.alb_log_bucket}-"
  acl    = "private"
  tags {
    Name        = "ALB Access logs"
    Environment = "${var.env}"
  }
}

resource "aws_s3_bucket_policy" "access_logs_policy" {
  bucket = "${aws_s3_bucket.access_logs.id}"
  policy = <<POLICY
{
  "Id": "Policy",
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": [
        "s3:PutObject"
      ],
      "Effect": "Allow",
      "Resource": "arn:aws:s3:::${aws_s3_bucket.access_logs.id}/*",
      "Principal": {
        "AWS": [
          "${data.aws_elb_service_account.main.arn}"
        ]
      }
    }
  ]
}
POLICY
}

resource "aws_alb" "vault" {
  name_prefix     = "vault-"
  security_groups = ["${aws_security_group.lb-vault-sg.id}"]
  internal        = false
  subnets         = ["${var.subnets}"]

  tags {
    Environment = "${var.env}"
    VPC         = "${local.vpc_name}"
  }

  access_logs {
    bucket = "${aws_s3_bucket.access_logs.id}"
    prefix = "logs/elb/${local.vpc_name}/vault"
  }
}

# DNS Alias for the LB
resource "aws_route53_record" "vault" {
  zone_id = "${data.aws_route53_zone.zone.zone_id}"
  name    = "${coalesce(var.hostname, "vault")}.${data.aws_route53_zone.zone.name}"
  type    = "A"

  alias {
    name                   = "${aws_alb.vault.dns_name}"
    zone_id                = "${aws_alb.vault.zone_id}"
    evaluate_target_health = false
  }
}

# Create a new target group
resource "aws_alb_target_group" "vault_ui" {
  port                 = 8200
  protocol             = "HTTP"
  deregistration_delay = "${var.lb_deregistration_delay}"
  vpc_id               = "${data.aws_vpc.vpc.id}"

  health_check {
    path    = "/v1/sys/health?standbyok=true"
    matcher = "200"
  }

  stickiness {
    type    = "lb_cookie"
    enabled = true
  }

  tags {
    Environment = "${var.env}"
    VPC         = "${local.vpc_name}"
  }
}

# Create a new alb listener
resource "aws_alb_listener" "vault_https" {
  load_balancer_arn = "${aws_alb.vault.arn}"
  port              = "443"
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-2015-05"
  certificate_arn   = "${data.aws_acm_certificate.cert.arn}" # edit needed

  default_action {
    target_group_arn = "${aws_alb_target_group.vault_ui.arn}"
    type             = "forward"
  }
}
