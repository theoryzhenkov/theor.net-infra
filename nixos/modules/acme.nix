{ config, pkgs, lib, ... }:

{
  security.acme = {
    acceptTerms = true;
    defaults = {
      email = "theo@theor.net";
    };
  };
}

