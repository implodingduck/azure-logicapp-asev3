terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "=3.36.0"
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
  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }

  subscription_id = var.subscription_id
}

locals {
  func_name = "ase${random_string.unique.result}"
  loc_for_naming = lower(replace(var.location, " ", ""))
  gh_repo = replace(var.gh_repo, "implodingduck/", "")
  tags = {
    "managed_by" = "terraform"
    "repo"       = local.gh_repo
  }
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

data "azurerm_network_security_group" "basic" {
    name                = "basic"
    resource_group_name = "rg-network-eastus"
}

resource "azurerm_resource_group" "rg" {
  name     = "rg-${local.gh_repo}-${random_string.unique.result}-${local.loc_for_naming}"
  location = var.location
  tags = local.tags
}

resource "azurerm_virtual_network" "default" {
  name                = "${local.func_name}-vnet-eastus"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  address_space       = ["10.1.0.0/16"]

  tags = local.tags
}


resource "azurerm_subnet" "default" {
  name                 = "default-subnet-eastus"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.default.name
  address_prefixes     = ["10.1.0.0/24"]
}

resource "azurerm_subnet" "ase" {
  name                 = "ase-subnet-eastus"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.default.name
  address_prefixes     = ["10.1.1.0/24"]
  delegation {
    name = "delegation"

    service_delegation {
      name    = "Microsoft.Web/hostingEnvironments"
      actions = [
        "Microsoft.Network/virtualNetworks/subnets/action"
      ]
    }
  }
}
resource "azurerm_subnet" "pe" {
  name                 = "snet-privateendpoints-${local.loc_for_naming}"
  resource_group_name  = azurerm_virtual_network.default.resource_group_name
  virtual_network_name = azurerm_virtual_network.default.name
  address_prefixes     = ["10.1.2.0/26"]

  private_endpoint_network_policies_enabled = true

}

resource "azurerm_private_dns_zone" "blob" {
  name                = "privatelink.blob.core.windows.net"
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_private_dns_zone" "file" {
  name                = "privatelink.file.core.windows.net"
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_private_dns_zone" "ase" {
  name                      = "${local.func_name}.appserviceenvironment.net"
  resource_group_name       = azurerm_resource_group.rg.name
}

# resource "azurerm_private_dns_zone_virtual_network_link" "appserviceenvironment_net_link" {
#   name                  = "${local.func_name}-link"
#   resource_group_name   = azurerm_resource_group.rg.name

#   private_dns_zone_name = azurerm_private_dns_zone.ase.name
#   virtual_network_id    = azurerm_virtual_network.default.id
# }

resource "azurerm_app_service_environment_v3" "ase3" {
  name                          	        = "${local.func_name}"
  resource_group_name                     = azurerm_resource_group.rg.name
  subnet_id                               = azurerm_subnet.ase.id
  #internal_load_balancing_mode            = "Web, Publishing" 
  allow_new_private_endpoint_connections  = false
  zone_redundant                          = false

  cluster_setting {
    name  = "DisableTls1.0"
    value = "1"
  }

  cluster_setting {
    name  = "InternalEncryption"
    value = "true"
  }
  tags = local.tags
}

resource "azurerm_private_dns_a_record" "wildcard_for_app_services" {
  name                = "*"
  zone_name           = azurerm_private_dns_zone.ase.name
  resource_group_name = azurerm_resource_group.rg.name
  ttl                 = 300
  records             = azurerm_app_service_environment_v3.ase3.internal_inbound_ip_addresses
}

resource "azurerm_private_dns_a_record" "wildcard_for_kudu" {
  name                = "*.scm"
  zone_name           = azurerm_private_dns_zone.ase.name
  resource_group_name = azurerm_resource_group.rg.name
  ttl                 = 300
  records             = azurerm_app_service_environment_v3.ase3.internal_inbound_ip_addresses
}

resource "azurerm_private_dns_a_record" "root_domain" {
  name                = "@"
  zone_name           = azurerm_private_dns_zone.ase.name
  resource_group_name = azurerm_resource_group.rg.name
  ttl                 = 300
  records             = azurerm_app_service_environment_v3.ase3.internal_inbound_ip_addresses
}


resource "azurerm_service_plan" "asp" {
  name                         = "${local.func_name}-asp"
  resource_group_name          = azurerm_resource_group.rg.name
  location                     = azurerm_resource_group.rg.location
  os_type                      = "Windows"
  app_service_environment_id   = azurerm_app_service_environment_v3.ase3.id
  sku_name                     = "I1v2"
  worker_count                 = 1
  #zone_balancing_enabled       = true
}

resource "azurerm_storage_account" "sa" {
  name                     = "sa${local.func_name}"
  resource_group_name      = azurerm_resource_group.rg.name
  location                 = azurerm_resource_group.rg.location
  account_kind             = "StorageV2"
  account_tier             = "Standard"
  account_replication_type = "LRS"
  allow_nested_items_to_be_public = false

  tags = local.tags
}

resource "azurerm_application_insights" "app" {
  name                = "${local.func_name}-insights"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  application_type    = "other"
  workspace_id        = data.azurerm_log_analytics_workspace.default.id
}

resource "azurerm_logic_app_standard" "example" {
  name                       = "la-${local.func_name}"
  location                   = azurerm_resource_group.rg.location
  resource_group_name        = azurerm_resource_group.rg.name
  app_service_plan_id        = azurerm_service_plan.asp.id
  storage_account_name       = azurerm_storage_account.sa.name
  storage_account_access_key = azurerm_storage_account.sa.primary_access_key
  app_settings = {
    "APPINSIGHTS_INSTRUMENTATIONKEY" = azurerm_application_insights.app.instrumentation_key
    "FUNCTIONS_WORKER_RUNTIME"       = "node"
    "WEBSITE_NODE_DEFAULT_VERSION"   = "~14"
  }

  site_config {
    ftps_state             = "Disabled"
    always_on              = true
    vnet_route_all_enabled = true
  }

  identity {
    type = "SystemAssigned"
  }
  tags = local.tags
}


# data "azurerm_storage_share" "content" {
#   name                 = "${azurerm_logic_app_standard.example.name}-content"
#   storage_account_name = azurerm_storage_account.sa.name
# }

# resource "azurerm_storage_share_directory" "dir" {

#   name                 = "site/wwwroot/stateless1"
#   share_name           = data.azurerm_storage_share.content.name
#   storage_account_name = azurerm_storage_account.sa.name
# }

# resource "azurerm_storage_share_file" "workflow" {
#   depends_on = [
#     azurerm_storage_share_directory.dir
#   ]
#   name             = "site/wwwroot/stateless1/workflow.json"
#   storage_share_id = data.azurerm_storage_share.content.id
#   source           = "../stateless1/workflow.json"
# }