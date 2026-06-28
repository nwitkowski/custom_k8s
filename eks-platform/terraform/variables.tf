variable "aws_region" {
  description = "AWS region the EKS cluster and its VPC are created in (the 'cluster region'). Students set the same value as CLUSTER_REGION in Lab 1. May differ from the Cloud9 region."
  type        = string
  default     = "us-east-2"
}

variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
  default     = "platform-lab"
}

variable "cluster_version" {
  description = "Kubernetes version"
  type        = string
  default     = "1.33"
}

variable "vpc_cidr" {
  description = "VPC CIDR block"
  type        = string
  default     = "10.0.0.0/16"
}

variable "node_instance_type" {
  description = "EC2 instance type for worker nodes"
  type        = string
  default     = "m5.2xlarge"
}

variable "node_desired" {
  type    = number
  default = 6
}

variable "node_min" {
  type    = number
  default = 4
}

variable "node_max" {
  type    = number
  default = 8
}

variable "enable_dns" {
  description = "Enable DNS features (cert-manager IRSA, external-dns, Let's Encrypt). Requires route53_zone_id and domain."
  type        = bool
  default     = false
}

variable "route53_zone_id" {
  description = "Route 53 hosted zone ID — only required if enable_dns = true"
  type        = string
  default     = ""
}

variable "domain" {
  description = "Base domain (e.g., example.com) — only required if enable_dns = true"
  type        = string
  default     = ""
}

variable "github_owner" {
  description = "GitHub org or username for Flux repo"
  type        = string
  default     = "jwkidd3"
}

variable "github_token" {
  description = "GitHub PAT for Flux bootstrap"
  type        = string
  sensitive   = true
}

variable "flux_repository_name" {
  description = "Name of the Git repo Flux will manage"
  type        = string
  default     = "fleet-infra"
}

variable "student_role_name" {
  description = "IAM role name for Cloud9 student instances (also used as instance profile name)"
  type        = string
  default     = "k8s-lab-role"
}

variable "vault_root_token" {
  description = "Vault dev root token"
  type        = string
  default     = "root"
  sensitive   = true
}
