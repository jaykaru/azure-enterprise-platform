variable "resource_group_name" {
  description = "Name of the Azure resource group for the platform."
  type        = string
}

variable "location" {
  description = "Azure region in which to create the resource group."
  type        = string
}

variable "environment" {
  description = "Deployment environment"
  type        = string
}

variable "tags" {
  description = "Tags applied to the resource group."
  type        = map(string)
  default     = {}
}
