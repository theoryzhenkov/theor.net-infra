terraform {
  required_version = ">= 1.5, < 2.0"

  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.49"
    }
    sops = {
      source  = "carlpett/sops"
      version = "~> 1.1"
    }
    porkbun = {
      source = "kyswtn/porkbun"
    }
    b2 = {
      source  = "Backblaze/b2"
      version = "~> 0.9"
    }
  }

  backend "local" {}
}
