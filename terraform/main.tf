terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "=3.19.1"
    }
    random = {
      source  = "hashicorp/random"
      version = "=3.1.0"
    }
    azapi = {
      source  = "Azure/azapi"
      version = "0.5.0"
    }
  }
  backend "azurerm" {

  }
}

provider "azurerm" {
  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }


  subscription_id = var.subscription_id
}

locals {
  func_name      = "logivnet${random_string.unique.result}"
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
  name                 = "snet-privateendpoints-${local.loc_for_naming}"
  resource_group_name  = azurerm_virtual_network.default.resource_group_name
  virtual_network_name = azurerm_virtual_network.default.name
  address_prefixes     = ["10.4.0.0/26"]

  private_endpoint_network_policies_enabled = true

}

resource "azurerm_subnet" "logicapps" {
  name                 = "snet-logicapps-${local.loc_for_naming}"
  resource_group_name  = azurerm_virtual_network.default.resource_group_name
  virtual_network_name = azurerm_virtual_network.default.name
  address_prefixes     = ["10.4.0.64/26"]
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
  name                = "privatelink.blob.core.windows.net"
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_private_dns_zone" "file" {
  name                = "privatelink.file.core.windows.net"
  resource_group_name = azurerm_resource_group.rg.name
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

resource "azurerm_private_endpoint" "pe-file" {
  name                = "pe-sa${local.func_name}-file"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  subnet_id           = azurerm_subnet.pe.id

  private_service_connection {
    name                           = "pe-connection-sa${local.func_name}-file"
    private_connection_resource_id = azurerm_storage_account.sa.id
    is_manual_connection           = false
    subresource_names              = ["file"]
  }
  private_dns_zone_group {
    name                 = azurerm_private_dns_zone.file.name
    private_dns_zone_ids = [azurerm_private_dns_zone.file.id]
  }
}

resource "azurerm_private_dns_zone_virtual_network_link" "blob" {
  name                  = "pdns-blob"
  resource_group_name   = azurerm_resource_group.rg.name
  private_dns_zone_name = azurerm_private_dns_zone.blob.name
  virtual_network_id    = azurerm_virtual_network.default.id
}

resource "azurerm_private_dns_zone_virtual_network_link" "file" {
  name                  = "pdns-file"
  resource_group_name   = azurerm_resource_group.rg.name
  private_dns_zone_name = azurerm_private_dns_zone.file.name
  virtual_network_id    = azurerm_virtual_network.default.id
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
  depends_on = [
    azurerm_app_service_virtual_network_swift_connection.example,
    azurerm_private_endpoint.pe,
    azurerm_private_endpoint.pe-file,

  ]
  storage_account_id = azurerm_storage_account.sa.id

  default_action = "Deny"

  virtual_network_subnet_ids = [azurerm_subnet.logicapps.id]
}
# resource "azapi_update_resource" "update_sa_fw" {
#   depends_on = [
#     azurerm_app_service_virtual_network_swift_connection.example
#   ]
#   type        = "Microsoft.Storage/storageAccounts@2021-09-01"
#   resource_id = azurerm_storage_account.sa.id

#   body = jsonencode({
#     properties = {
#       publicNetworkAccess = "Disabled"
#     }
#   })
# }

resource "azurerm_application_insights" "app" {
  name                = "${local.func_name}-insights"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  application_type    = "other"
  workspace_id        = data.azurerm_log_analytics_workspace.default.id
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
  depends_on = [
    azurerm_private_endpoint.pe,
    azurerm_private_endpoint.pe-file
  ]
  name                       = "la-${local.func_name}"
  location                   = azurerm_resource_group.rg.location
  resource_group_name        = azurerm_resource_group.rg.name
  app_service_plan_id        = azurerm_app_service_plan.asp.id
  storage_account_name       = azurerm_storage_account.sa.name
  storage_account_access_key = azurerm_storage_account.sa.primary_access_key
  app_settings = {
    "APPINSIGHTS_INSTRUMENTATIONKEY" = azurerm_application_insights.app.instrumentation_key
    "FUNCTIONS_WORKER_RUNTIME"       = "node"
    "WEBSITE_NODE_DEFAULT_VERSION"   = "~14"
    "SQL_PASSWORD"                   = random_password.password.result
    "sql_connectionString"           = "@Microsoft.KeyVault(VaultName=${azurerm_key_vault.kv.name};SecretName=${azurerm_key_vault_secret.dbconnectionstring.name})"
    "WEBSITE_CONTENTOVERVNET"        = "1"
  }

  site_config {
    dotnet_framework_version  = "v6.0"
    use_32_bit_worker_process = true
    vnet_route_all_enabled    = true
    ftps_state                = "Disabled"
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

resource "azurerm_key_vault" "kv" {
  name                       = "${local.func_name}-kv"
  location                   = azurerm_resource_group.rg.location
  resource_group_name        = azurerm_resource_group.rg.name
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  soft_delete_retention_days = 7
  purge_protection_enabled   = false



  tags = local.tags
}

resource "azurerm_key_vault_access_policy" "client-config" {
  key_vault_id = azurerm_key_vault.kv.id
  tenant_id    = data.azurerm_client_config.current.tenant_id
  object_id    = data.azurerm_client_config.current.object_id

  key_permissions = [
    "Create",
    "Get",
    "Purge",
    "Recover",
    "Delete"
  ]

  secret_permissions = [
    "Set",
    "Purge",
    "Get",
    "List",
    "Delete"
  ]

  certificate_permissions = [
    "Purge"
  ]

  storage_permissions = [
    "Purge"
  ]
}

resource "azurerm_key_vault_access_policy" "la" {
  key_vault_id = azurerm_key_vault.kv.id
  tenant_id    = data.azurerm_client_config.current.tenant_id
  object_id    = azurerm_logic_app_standard.example.identity.0.principal_id
  secret_permissions = [
    "Get",
    "List"
  ]
}

resource "random_password" "password" {
  length           = 16
  special          = true
  override_special = "_%@"
}

resource "azurerm_key_vault_secret" "dbpassword" {
  depends_on = [
    azurerm_key_vault_access_policy.client-config
  ]
  name         = "dbpassword"
  value        = random_password.password.result
  key_vault_id = azurerm_key_vault.kv.id
}

resource "azurerm_key_vault_secret" "dbconnectionstring" {
  depends_on = [
    azurerm_key_vault_access_policy.client-config
  ]
  name         = "dbconnectionstring"
  value        = "Server=tcp:${azurerm_mssql_server.db.fully_qualified_domain_name},1433;Initial Catalog=${azurerm_mssql_database.db.name};Persist Security Info=False;User ID=sqladmin;Password=${random_password.password.result};MultipleActiveResultSets=False;Encrypt=True;TrustServerCertificate=False;Connection Timeout=30;"
  key_vault_id = azurerm_key_vault.kv.id
}

resource "azurerm_mssql_server" "db" {
  name                         = "${local.func_name}-server"
  resource_group_name          = azurerm_resource_group.rg.name
  location                     = azurerm_resource_group.rg.location
  version                      = "12.0"
  administrator_login          = "sqladmin"
  administrator_login_password = random_password.password.result
  minimum_tls_version          = "1.2"

  tags = local.tags
}

resource "azurerm_mssql_database" "db" {
  name                        = "${local.func_name}db"
  server_id                   = azurerm_mssql_server.db.id
  max_size_gb                 = 40
  auto_pause_delay_in_minutes = -1
  min_capacity                = 1
  sku_name                    = "GP_S_Gen5_1"
  tags                        = local.tags
  short_term_retention_policy {
    retention_days = 7
  }
}

resource "azurerm_mssql_firewall_rule" "azureservices" {
  name             = "azureservices"
  server_id        = azurerm_mssql_server.db.id
  start_ip_address = "0.0.0.0"
  end_ip_address   = "0.0.0.0"
}

resource "azurerm_mssql_firewall_rule" "vnet" {
  name             = "vnet"
  server_id        = azurerm_mssql_server.db.id
  start_ip_address = "10.4.0.0"
  end_ip_address   = "10.4.0.255"
}

resource "azurerm_mssql_firewall_rule" "allthethings" {
  name             = "allthethings"
  server_id        = azurerm_mssql_server.db.id
  start_ip_address = "0.0.0.0"
  end_ip_address   = "255.255.255.255"
}