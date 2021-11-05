terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "=2.83.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "=3.1.0"
    }
  }
  backend "azurerm" {

  }
}

provider "azurerm" {
  features {}

  subscription_id = var.subscription_id
}

locals {
  func_name = "logivnet${random_string.unique.result}"
  loc_for_naming = lower(replace(var.location, " ", ""))
  tags = {
    "managed_by" = "terraform"
    "repo"       = "azure-logicapp-vnet"
  }
}

resource "azurerm_resource_group" "rg" {
  name     = "rg-${local.func_name}-${local.loc_for_naming}"
  location = var.location
}

resource "random_string" "unique" {
  length  = 8
  special = false
  upper   = false
}


data "azurerm_client_config" "current" {}

data "azurerm_log_analytics_workspace" "default" {
  name                = "DefaultWorkspace-${data.azurerm_client_config.current.subscription_id}-EUS"
  resource_group_name = "DefaultResourceGroup-EUS"
} 

resource "azurerm_virtual_network" "default" {
  name                = "vnet-${local.func_name}-${local.loc_for_naming}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  address_space       = ["10.4.0.0/24"]

  tags = local.tags
}

resource "azurerm_subnet" "pe" {
  name                  = "snet-privateendpoints-${local.loc_for_naming}"
  resource_group_name   = azurerm_virtual_network.default.resource_group_name
  virtual_network_name  = azurerm_virtual_network.default.name
  address_prefixes      = ["10.4.0.0/26"]

  enforce_private_link_endpoint_network_policies = true

}

resource "azurerm_subnet" "logicapps" {
  name                  = "snet-logicapps-${local.loc_for_naming}"
  resource_group_name   = azurerm_virtual_network.default.resource_group_name
  virtual_network_name  = azurerm_virtual_network.default.name
  address_prefixes      = ["10.4.0.64/26"]
  service_endpoints = [
    "Microsoft.Web",
    "Microsoft.Storage"
  ]
  delegation {
    name = "serverfarm-delegation"
    service_delegation {
      name = "Microsoft.Web/serverFarms"
    }
  }
  

 
}


resource "azurerm_private_dns_zone" "blob" {
  name                      = "privatelink.blob.core.windows.net"
  resource_group_name       = azurerm_resource_group.rg.name
}

resource "azurerm_private_endpoint" "pe" {
  name                = "pe-sa${local.func_name}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  subnet_id           = azurerm_subnet.pe.id

  private_service_connection {
    name                           = "pe-connection-sa${local.func_name}"
    private_connection_resource_id = azurerm_storage_account.sa.id
    is_manual_connection           = false
    subresource_names              = ["blob"]
  }
  private_dns_zone_group {
    name                 = azurerm_private_dns_zone.blob.name
    private_dns_zone_ids = [azurerm_private_dns_zone.blob.id]
  }
}

resource "azurerm_storage_account" "sa" {
  name                     = "sa${local.func_name}"
  resource_group_name      = azurerm_resource_group.rg.name
  location                 = azurerm_resource_group.rg.location
  account_kind             = "StorageV2"
  account_tier             = "Standard"
  account_replication_type = "LRS"

  tags = local.tags
}

resource "azurerm_storage_account_network_rules" "fw" {
  storage_account_id = azurerm_storage_account.sa.id

  default_action             = "Allow"

  virtual_network_subnet_ids = [azurerm_subnet.logicapps.id]
}

resource "azurerm_app_service_plan" "asp" {
  name                = "asp-${local.func_name}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  kind                = "elastic"
  reserved            = false
    sku {
    tier = "WorkflowStandard"
    size = "WS1"
  }
  tags = local.tags
}

resource "azurerm_logic_app_standard" "example" {
  name                       = "la-${local.func_name}"
  location                   = azurerm_resource_group.rg.location
  resource_group_name        = azurerm_resource_group.rg.name
  app_service_plan_id        = azurerm_app_service_plan.asp.id
  storage_account_name       = azurerm_storage_account.sa.name
  storage_account_access_key = azurerm_storage_account.sa.primary_access_key
  app_settings = {
    "FUNCTIONS_WORKER_RUNTIME"      = "node"
    "WEBSITE_NODE_DEFAULT_VERSION" = "~12"
  }
  identity {
    type = "SystemAssigned"
  }
  tags = local.tags
}


resource "azurerm_app_service_virtual_network_swift_connection" "example" {
  app_service_id = azurerm_logic_app_standard.example.id
  subnet_id      = azurerm_subnet.logicapps.id
}