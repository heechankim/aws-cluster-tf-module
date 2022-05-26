locals {
  http_port = 80
  any_port = 0
  any_protocol = "-1"
  tcp_protocol = "tcp"
  all_ips = ["0.0.0.0/0"]
}

# ---

data "aws_vpc" "default-vpc" {
  tags = {
    ref = "default-vpc"
  }
}

data "aws_subnets" "default-sn" {
  filter {
    name = "vpc-id"
    values = [data.aws_vpc.default-vpc.id]
  }
}

data "aws_subnet" "default-public1" {
  filter {
    name = "tag:ref"
    values = ["public1"]
  }
}
data "aws_subnet" "default-public2" {
  filter {
    name = "tag:ref"
    values = ["public2"]
  }
}

data "terraform_remote_state" "db" {
  backend = "s3"

  config = {
    bucket = var.db_remote_state_bucket
    key = var.db_remote_state_key 
    region = "ap-northeast-2"
  }
}

# ----

resource "aws_security_group" "instance" {
  name = "${var.cluster_name}-instance"
  vpc_id = data.aws_vpc.default-vpc.id
}

resource "aws_security_group_rule" "allow_server_inbound" {
  type = "ingress"
  security_group_id = aws_security_group.instance.id

  from_port = var.server_port
  to_port = var.server_port
  protocol = local.tcp_protocol
  cidr_blocks = local.all_ips
}

resource "aws_launch_configuration" "example" {
  image_id = "ami-063454de5fe8eba79"
  instance_type = var.instance_type

  security_groups = [aws_security_group.instance.id]

  user_data = <<-EOF
                #!/bin/bash
                echo "<h1>Hello World!!</h1><br><br><hr>" > index.html
                echo "<h3>${var.cluster_name}</h3>" >> index.html
                echo "Host: `uname -a`<br>" >> index.html
                echo "DB Address: ${data.terraform_remote_state.db.outputs.address}<br>" >> index.html
                echo "DB Port: ${data.terraform_remote_state.db.outputs.port}<br>" >> index.html
                nohup busybox httpd -f -p ${var.server_port} &
                EOF

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_group" "example" {
  launch_configuration = aws_launch_configuration.example.name
  vpc_zone_identifier = [data.aws_subnet.default-public1.id, data.aws_subnet.default-public2.id]

  target_group_arns = [aws_lb_target_group.asg.arn]
  health_check_type = "ELB"

  min_size = var.min_size
  max_size = var.max_size

  tag {
    key = "Name"
    value = "${var.cluster_name}" 
    propagate_at_launch = true
  }
}

resource "aws_security_group" "alb" {
  name = "${var.cluster_name}-alb"
  vpc_id = data.aws_vpc.default-vpc.id
}

resource "aws_security_group_rule" "allow_http_inbound" {
  type = "ingress"
  security_group_id = aws_security_group.alb.id

  from_port = local.http_port
  to_port = local.http_port
  protocol = local.tcp_protocol
  cidr_blocks = local.all_ips
}

resource "aws_security_group_rule" "allow_all_outbound" {
  type = "egress"
  security_group_id = aws_security_group.alb.id

  from_port = local.any_port
  to_port = local.any_port
  protocol = local.any_protocol
  cidr_blocks = local.all_ips
}

resource "aws_lb" "example" {
  name = "${var.cluster_name}-lb"
  internal = false
  load_balancer_type = "application"

  subnets = [data.aws_subnet.default-public1.id, data.aws_subnet.default-public2.id]
  security_groups = [aws_security_group.alb.id]

}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.example.arn
  port = local.http_port
  protocol = "HTTP"

  default_action {
    type = "fixed-response"

    fixed_response {
      content_type = "text/plain"
      message_body = "404: page not found"
      status_code = 404
    }
  }
}

resource "aws_lb_listener_rule" "asg" {
  listener_arn = aws_lb_listener.http.arn
  priority = 100

  condition {
    path_pattern {
      values = ["*"]
    }
  }

  action {
    type = "forward"
    target_group_arn = aws_lb_target_group.asg.arn
  }

}

resource "aws_lb_target_group" "asg" {
  name = "${var.cluster_name}-target-group"
  port = var.server_port
  protocol = "HTTP"
  vpc_id = data.aws_vpc.default-vpc.id

  health_check {
    path = "/"
    protocol = "HTTP"
    matcher = "200"
    interval = 15
    timeout = 3
    healthy_threshold = 2
    unhealthy_threshold = 2
  }
}





























