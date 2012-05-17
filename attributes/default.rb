
include_attribute "solo_client::default"

default.deployment[:elbs] = {}
default.deployment[:elbs][:appdb] = nil
default.deployment[:elbs][:openpub] = nil
default.deployment[:elbs][:minipax] = nil
default.deployment[:elbs]["gd-app"] = nil
default.deployment[:elbs]["cb-apache"] = nil

