variable "airflow_instance_type" {
  description = "EC2 instance type for Airflow. t3.small with SequentialExecutor + SQLite is deliberately undersized for a real production Airflow deployment — see ADR 0014."
  type        = string
  default     = "t3.medium"
}

variable "airflow_instance_state" {
  description = <<-EOT
    "running" or "stopped". Toggles EC2 power state WITHOUT destroying the
    instance, its disk, or anything installed on it. Flip this and apply to
    pause or resume — the instance, DAG files, and Airflow metadata DB all
    survive a stop. Default is "stopped" so a fresh `terraform apply` does
    not accidentally start (and start billing) an instance nobody asked for.
  EOT
  type        = string
  default     = "running"

  validation {
    condition     = contains(["running", "stopped"], var.airflow_instance_state)
    error_message = "airflow_instance_state must be \"running\" or \"stopped\"."
  }
}
