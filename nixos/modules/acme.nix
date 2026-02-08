{ config, pkgs, lib, ... }:

{
  security.acme = {
    acceptTerms = true;
    defaults = {
      email = "theo@the-o.space";
    };
  };
}

