variable "keda_namespace" {
  description = "Namespace for KEDA installation"
  type        = string
  default     = "keda"
}

variable "tags" {
  description = "Additional tags"
  type        = map(string)
  default     = {}
}
